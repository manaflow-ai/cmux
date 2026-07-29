package cmux

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/manaflow-ai/cmux/cmux-tui/bindings/go/internal/wirev1"
)

const (
	MaxRequestBytes        = 4 * 1024 * 1024
	MaxResponseBytes       = 16 * 1024 * 1024
	MaxStreamQueueMessages = 256
	MaxStreamQueueBytes    = 16 * 1024 * 1024
)

var errFrameTooLarge = errors.New("cmux server frame too large")

type DialContextFunc func(context.Context, string, string) (net.Conn, error)
type IdempotencyKeyFunc func() (string, error)

type ClientOptions struct {
	SocketPath       string
	Session          string
	Timeout          time.Duration
	DialContext      DialContextFunc
	IdempotencyKey   IdempotencyKeyFunc
	MaxRequestBytes  int
	MaxResponseBytes int
}

type responseEnvelope struct {
	Protocol string          `json:"protocol"`
	Type     string          `json:"type"`
	ID       string          `json:"id"`
	OK       bool            `json:"ok"`
	Result   json.RawMessage `json:"result"`
	Error    *struct {
		Code      string          `json:"code"`
		Message   string          `json:"message"`
		Details   json.RawMessage `json:"details"`
		Retryable bool            `json:"retryable"`
	} `json:"error"`
}

type streamEnvelope struct {
	Protocol string          `json:"protocol"`
	Type     string          `json:"type"`
	StreamID StreamID        `json:"stream_id"`
	Sequence Decimal         `json:"sequence"`
	Cursor   *Cursor         `json:"cursor"`
	Item     json.RawMessage `json:"item"`
	Reason   string          `json:"reason"`
	Error    *struct {
		Code      string          `json:"code"`
		Message   string          `json:"message"`
		Details   json.RawMessage `json:"details"`
		Retryable bool            `json:"retryable"`
	} `json:"error"`
	Recovery string `json:"recovery"`
}

type pendingResponse struct {
	envelope responseEnvelope
	err      error
}

type streamRoute struct {
	messages     chan streamMessage
	mu           sync.Mutex
	accepting    bool
	terminated   bool
	queuedBytes  int
	cancelParams map[string]any
}

type streamMessage struct {
	envelope streamEnvelope
	err      error
	size     int
}

// Client is the high-level resource API connection. It never retries a
// mutation. All request, stream, cancellation, and close I/O is caller
// cancellable through context.Context.
type Client struct {
	conn             net.Conn
	reader           *bufio.Reader
	timeout          time.Duration
	maxRequestBytes  int
	maxResponseBytes int
	idempotencyKey   IdempotencyKeyFunc
	writer           chan struct{}
	nextRequestID    atomic.Uint64

	mu      sync.Mutex
	pending map[string]chan pendingResponse
	streams map[StreamID]*streamRoute
	closed  bool
	done    chan struct{}
	err     error
}

func NewClient(ctx context.Context, options ClientOptions) (*Client, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	timeout := options.Timeout
	if timeout == 0 {
		timeout = 10 * time.Second
	}
	if timeout < 0 {
		return nil, fmt.Errorf("%w: timeout must not be negative", ErrInvalidArgument)
	}
	maxRequest := options.MaxRequestBytes
	if maxRequest == 0 {
		maxRequest = MaxRequestBytes
	}
	maxResponse := options.MaxResponseBytes
	if maxResponse == 0 {
		maxResponse = MaxResponseBytes
	}
	if maxRequest < 1 || maxResponse < 1 {
		return nil, fmt.Errorf("%w: message limits must be positive", ErrInvalidArgument)
	}
	socket := options.SocketPath
	if socket == "" {
		socket = defaultSocketPath(options.Session)
	}
	dial := options.DialContext
	if dial == nil {
		var dialer net.Dialer
		dial = dialer.DialContext
	}
	keySource := options.IdempotencyKey
	if keySource == nil {
		keySource = newIdempotencyKey
	}
	conn, err := dial(ctx, "unix", socket)
	if err != nil {
		return nil, &TransportError{Operation: "connect", Err: err}
	}
	client := &Client{
		conn:             conn,
		reader:           bufio.NewReaderSize(conn, 64*1024),
		timeout:          timeout,
		maxRequestBytes:  maxRequest,
		maxResponseBytes: maxResponse,
		idempotencyKey:   keySource,
		writer:           make(chan struct{}, 1),
		pending:          make(map[string]chan pendingResponse),
		streams:          make(map[StreamID]*streamRoute),
		done:             make(chan struct{}),
	}
	client.writer <- struct{}{}
	go client.readLoop()
	return client, nil
}

func (c *Client) Close(ctx context.Context) error {
	if c == nil {
		return nil
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	c.fail(&TransportError{Operation: "close", Err: ErrClosed})
	return nil
}

func (c *Client) do(
	ctx context.Context,
	operation wirev1.Operation,
	params map[string]any,
	idempotencyKey string,
	result any,
) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	switch operation.Class {
	case wirev1.Mutation:
		if idempotencyKey == "" {
			var err error
			idempotencyKey, err = c.idempotencyKey()
			if err != nil {
				return &TransportError{Operation: operation.Name, Err: err}
			}
		}
		if len(idempotencyKey) > 128 {
			return fmt.Errorf("%w: mutation idempotency key must contain at most 128 bytes", ErrInvalidArgument)
		}
	default:
		if idempotencyKey != "" {
			return fmt.Errorf("%w: %s does not accept an idempotency key", ErrInvalidArgument, operation.Name)
		}
	}
	requestID := "go-" + strconv.FormatUint(c.nextRequestID.Add(1), 10)
	request := map[string]any{
		"protocol":  wirev1.Protocol,
		"type":      "request",
		"id":        requestID,
		"operation": operation.Name,
		"params":    params,
	}
	if idempotencyKey != "" {
		request[wirev1.FieldIdempotencyKey] = idempotencyKey
	}
	uncertain := func(err error) error {
		if operation.Class != wirev1.Mutation {
			return err
		}
		return &MutationTransportUncertainError{
			Operation: operation.Name, IdempotencyKey: idempotencyKey, Err: err,
		}
	}
	waiter := make(chan pendingResponse, 1)
	c.mu.Lock()
	if c.closed {
		err := c.err
		c.mu.Unlock()
		if err == nil {
			err = ErrClosed
		}
		return err
	}
	c.pending[requestID] = waiter
	c.mu.Unlock()
	mayHaveSent, err := c.write(ctx, operation.Name, request)
	if err != nil {
		c.removePending(requestID)
		if mayHaveSent {
			return uncertain(err)
		}
		return err
	}
	handleResponse := func(response pendingResponse) error {
		if response.err != nil {
			return uncertain(response.err)
		}
		if !response.envelope.OK {
			if response.envelope.Error == nil {
				return &ProtocolError{Message: "failed response omitted error"}
			}
			return &ResourceError{
				Code:      response.envelope.Error.Code,
				Message:   response.envelope.Error.Message,
				Details:   cloneRaw(response.envelope.Error.Details),
				Retryable: response.envelope.Error.Retryable,
			}
		}
		if result == nil {
			return nil
		}
		decoder := json.NewDecoder(bytes.NewReader(response.envelope.Result))
		decoder.UseNumber()
		if err := decoder.Decode(result); err != nil {
			return &ProtocolError{Message: "cannot decode " + operation.Name + " result: " + err.Error()}
		}
		return nil
	}
	select {
	case response := <-waiter:
		return handleResponse(response)
	case <-ctx.Done():
		c.removePending(requestID)
		return uncertain(ctx.Err())
	case <-c.done:
		// Preserve a response that raced with transport shutdown.
		select {
		case response, ok := <-waiter:
			if ok {
				return handleResponse(response)
			}
		default:
		}
		return uncertain(c.connectionError())
	}
}

func (c *Client) write(
	ctx context.Context,
	operation string,
	value any,
) (bool, error) {
	encoded, err := json.Marshal(value)
	if err != nil {
		return false, &ProtocolError{
			Message: "cannot encode " + operation + ": " + err.Error(),
		}
	}
	if len(encoded) > c.maxRequestBytes {
		return false, fmt.Errorf(
			"%w: %s request exceeds %d bytes",
			ErrInvalidArgument,
			operation,
			c.maxRequestBytes,
		)
	}
	select {
	case <-ctx.Done():
		return false, ctx.Err()
	case <-c.done:
		return false, c.connectionError()
	case <-c.writer:
	}
	defer func() { c.writer <- struct{}{} }()
	deadline := time.Now().Add(c.timeout)
	if contextDeadline, ok := ctx.Deadline(); ok && contextDeadline.Before(deadline) {
		deadline = contextDeadline
	}
	if err := c.conn.SetWriteDeadline(deadline); err != nil {
		return false, &TransportError{Operation: operation, Err: err}
	}
	encoded = append(encoded, '\n')
	written := false
	for len(encoded) > 0 {
		if err := ctx.Err(); err != nil {
			return written, err
		}
		count, err := c.conn.Write(encoded)
		written = written || count > 0
		if err != nil {
			return written, &TransportError{Operation: operation, Err: err}
		}
		if count == 0 {
			return written, &TransportError{
				Operation: operation,
				Err:       io.ErrNoProgress,
			}
		}
		encoded = encoded[count:]
	}
	return true, nil
}

func (c *Client) readLoop() {
	for {
		line, err := readBoundedLine(c.reader, c.maxResponseBytes)
		if err != nil {
			if errors.Is(err, errFrameTooLarge) {
				c.fail(&ProtocolError{Message: fmt.Sprintf("server message exceeds %d bytes", c.maxResponseBytes)})
				return
			}
			if errors.Is(err, io.EOF) {
				err = io.ErrUnexpectedEOF
			}
			c.fail(&TransportError{Operation: "read", Err: err})
			return
		}
		line = bytes.TrimSuffix(line, []byte{'\n'})
		line = bytes.TrimSuffix(line, []byte{'\r'})
		if len(bytes.TrimSpace(line)) == 0 {
			continue
		}
		var header struct {
			Protocol string   `json:"protocol"`
			Type     string   `json:"type"`
			ID       string   `json:"id"`
			StreamID StreamID `json:"stream_id"`
		}
		if err := json.Unmarshal(line, &header); err != nil {
			c.fail(&ProtocolError{Message: "invalid JSON from server: " + err.Error()})
			return
		}
		if header.Protocol != wirev1.Protocol {
			c.fail(&ProtocolError{Message: "unexpected protocol " + header.Protocol})
			return
		}
		switch header.Type {
		case "response":
			var response responseEnvelope
			if err := json.Unmarshal(line, &response); err != nil {
				c.fail(&ProtocolError{Message: "invalid response: " + err.Error()})
				return
			}
			c.mu.Lock()
			waiter := c.pending[response.ID]
			delete(c.pending, response.ID)
			c.mu.Unlock()
			if waiter != nil {
				waiter <- pendingResponse{envelope: response}
				close(waiter)
			}
		case "stream_item", "stream_end":
			var envelope streamEnvelope
			if err := json.Unmarshal(line, &envelope); err != nil {
				c.fail(&ProtocolError{Message: "invalid stream envelope: " + err.Error()})
				return
			}
			c.deliverStream(envelope, len(line))
		default:
			c.fail(&ProtocolError{Message: "unexpected envelope type " + header.Type})
			return
		}
	}
}

func (c *Client) deliverStream(envelope streamEnvelope, size int) {
	c.mu.Lock()
	route := c.streams[envelope.StreamID]
	if envelope.Type == "stream_end" {
		delete(c.streams, envelope.StreamID)
	}
	c.mu.Unlock()
	if route == nil {
		return
	}
	if route.deliver(streamMessage{envelope: envelope, size: size}) {
		return
	}
	if envelope.Type != "stream_end" {
		c.mu.Lock()
		delete(c.streams, envelope.StreamID)
		c.mu.Unlock()
		route.overflow()
		go func() {
			_ = c.cancelStream(context.Background(), route.cancelParams)
		}()
	}
}

func (c *Client) fail(err error) {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return
	}
	c.closed = true
	c.err = err
	close(c.done)
	pending := c.pending
	streams := c.streams
	c.pending = make(map[string]chan pendingResponse)
	c.streams = make(map[StreamID]*streamRoute)
	c.mu.Unlock()
	_ = c.conn.Close()
	for _, waiter := range pending {
		waiter <- pendingResponse{err: err}
		close(waiter)
	}
	for _, route := range streams {
		route.finish(err)
	}
}

func (r *streamRoute) finish(err error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.terminated {
		return
	}
	r.accepting = false
	r.terminated = true
	r.purgeLocked()
	r.messages <- streamMessage{err: err}
}

func (r *streamRoute) cancelTerminal() *StreamEndError {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.accepting = false
	r.terminated = true
	var end *StreamEndError
	for {
		select {
		case message := <-r.messages:
			r.queuedBytes -= message.size
			if message.envelope.Type == "stream_end" {
				end = streamEndFromEnvelope(message.envelope)
			} else if candidate, ok := message.err.(*StreamEndError); ok {
				end = candidate
			}
		default:
			r.queuedBytes = 0
			return end
		}
	}
}

func (r *streamRoute) deliver(message streamMessage) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.accepting || r.terminated {
		return false
	}
	if message.envelope.Type != "stream_end" &&
		(len(r.messages) >= MaxStreamQueueMessages ||
			r.queuedBytes+message.size > MaxStreamQueueBytes) {
		return false
	}
	if message.envelope.Type == "stream_end" {
		r.accepting = false
	}
	select {
	case r.messages <- message:
		r.queuedBytes += message.size
		return true
	default:
		return false
	}
}

func (r *streamRoute) consumed(size int) {
	r.mu.Lock()
	r.queuedBytes -= size
	if r.queuedBytes < 0 {
		r.queuedBytes = 0
	}
	r.mu.Unlock()
}

func (r *streamRoute) overflow() {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.terminated {
		return
	}
	r.accepting = false
	r.terminated = true
	r.purgeLocked()
	r.messages <- streamMessage{err: &StreamEndError{
		Reason: "gap",
		ResourceError: &ResourceError{
			Code:      "stream.local_overflow",
			Message:   "local stream queue exceeded its bounded capacity",
			Details:   json.RawMessage(`{"message_limit":256,"byte_limit":16777216}`),
			Retryable: true,
		},
		Recovery: "open a fresh stream to receive a new snapshot",
	}}
}

func (r *streamRoute) purgeLocked() {
	for {
		select {
		case message := <-r.messages:
			r.queuedBytes -= message.size
		default:
			r.queuedBytes = 0
			return
		}
	}
}

func (c *Client) removePending(id string) {
	c.mu.Lock()
	delete(c.pending, id)
	c.mu.Unlock()
}

func (c *Client) connectionError() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.err != nil {
		return c.err
	}
	return ErrClosed
}

func newStreamID() (StreamID, error) {
	var entropy [16]byte
	if _, err := rand.Read(entropy[:]); err != nil {
		return "", err
	}
	return StreamID("stream_" + hex.EncodeToString(entropy[:])), nil
}

func newIdempotencyKey() (string, error) {
	var entropy [16]byte
	if _, err := rand.Read(entropy[:]); err != nil {
		return "", err
	}
	return "idem_" + hex.EncodeToString(entropy[:]), nil
}

func cloneRaw(value json.RawMessage) json.RawMessage {
	return append(json.RawMessage(nil), value...)
}

func readBoundedLine(reader *bufio.Reader, maxBytes int) ([]byte, error) {
	line := make([]byte, 0, min(maxBytes+1, 64*1024))
	for {
		fragment, err := reader.ReadSlice('\n')
		if len(line)+len(fragment) > maxBytes+1 {
			return nil, errFrameTooLarge
		}
		line = append(line, fragment...)
		switch {
		case err == nil:
			if len(line) == 0 || line[len(line)-1] != '\n' {
				return nil, io.ErrUnexpectedEOF
			}
			return line, nil
		case errors.Is(err, bufio.ErrBufferFull):
			continue
		default:
			return nil, err
		}
	}
}
