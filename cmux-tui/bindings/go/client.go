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
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/manaflow-ai/cmux/cmux-tui/bindings/go/internal/wirev2"
)

const (
	MaxRequestBytes                = 4 * 1024 * 1024
	MaxResponseBytes               = 16 * 1024 * 1024
	MaxStreamQueueMessages         = 256
	MaxStreamQueueBytes            = 16 * 1024 * 1024
	failedStreamOpenCleanupTimeout = time.Second
	abandonedRequestCleanupTimeout = time.Second
)

var errFrameTooLarge = errors.New("cmux server frame too large")

type DialContextFunc func(context.Context, string, string) (net.Conn, error)
type IdempotencyKeyFunc func() (string, error)

type ClientOptions struct {
	SocketPath string
	Session    string
	// SessionSet distinguishes an explicitly supplied Session from omission.
	// When false, an empty Session selects "main". When true, an empty Session
	// is invalid if socket discovery needs a session name.
	SessionSet       bool
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
	Error    *ResourceError  `json:"error"`
}

type streamEnvelope struct {
	Protocol string          `json:"protocol"`
	Type     string          `json:"type"`
	StreamID StreamID        `json:"stream_id"`
	Sequence Decimal         `json:"sequence"`
	Cursor   *Cursor         `json:"cursor"`
	Item     json.RawMessage `json:"item"`
	Reason   string          `json:"reason"`
	Error    *ResourceError  `json:"error"`
	Recovery string          `json:"recovery"`
}

type responseEnvelopeWire struct {
	Protocol *string         `json:"protocol"`
	Type     *string         `json:"type"`
	ID       *string         `json:"id"`
	OK       *bool           `json:"ok"`
	Result   json.RawMessage `json:"result"`
	Error    json.RawMessage `json:"error"`
}

type streamItemEnvelopeWire struct {
	Protocol *string         `json:"protocol"`
	Type     *string         `json:"type"`
	StreamID json.RawMessage `json:"stream_id"`
	Sequence json.RawMessage `json:"sequence"`
	Cursor   json.RawMessage `json:"cursor"`
	Item     json.RawMessage `json:"item"`
}

type streamEndEnvelopeWire struct {
	Protocol *string         `json:"protocol"`
	Type     *string         `json:"type"`
	StreamID json.RawMessage `json:"stream_id"`
	Reason   *string         `json:"reason"`
	Cursor   json.RawMessage `json:"cursor"`
	Error    json.RawMessage `json:"error"`
	Recovery json.RawMessage `json:"recovery"`
}

type resourceErrorWire struct {
	Code      *string         `json:"code"`
	Message   *string         `json:"message"`
	Details   json.RawMessage `json:"details"`
	Retryable *bool           `json:"retryable"`
}

type pendingResponse struct {
	envelope responseEnvelope
	err      error
}

type requestCancelResultWire struct {
	Canceled *bool `json:"canceled"`
}

type abandonedRequestCleanup struct {
	once sync.Once
	done chan struct{}
	err  error
}

type streamRoute struct {
	messages         chan streamMessage
	mu               sync.Mutex
	accepting        bool
	terminated       bool
	serverEnded      bool
	queuedBytes      int
	cancelParams     map[string]any
	openDispatched   bool
	openAcknowledged bool
	cleanupStarted   bool
	cancelItem       func(streamEnvelope) error
	cancelSignal     chan struct{}
	cancelEnd        *streamEnvelope
	cancelErr        error
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
	framingUnsafe    bool // guarded by writer
	nextRequestID    atomic.Uint64

	requestCleanupMu   sync.Mutex
	requestCleanups    int
	requestCleanupDone chan struct{}

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
	session := options.Session
	if session == "" && !options.SessionSet {
		session = "main"
	}
	if socket == "" {
		var err error
		socket, err = resolveSocketPath("", session)
		if err != nil {
			return nil, err
		}
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
	if err != nil && options.SocketPath == "" && envSocketPath() == "" &&
		(errors.Is(err, syscall.ENOENT) || errors.Is(err, syscall.ECONNREFUSED)) {
		legacy := legacySocketPathForResolvedSession(socket, session)
		if legacy != "" {
			if fallbackConn, fallbackErr := dial(ctx, "unix", legacy); fallbackErr == nil {
				conn, err = fallbackConn, nil
			} else {
				err = errors.Join(err, fmt.Errorf("legacy socket %s: %w", legacy, fallbackErr))
			}
		}
	}
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
	c.failWithCleanupContext(ctx, &TransportError{Operation: "close", Err: ErrClosed}, true)
	return nil
}

func (c *Client) do(
	ctx context.Context,
	operation wirev2.Operation,
	params map[string]any,
	idempotencyKey string,
	result any,
) error {
	return c.doTracked(ctx, operation, params, idempotencyKey, result, nil)
}

func (c *Client) doTracked(
	ctx context.Context,
	operation wirev2.Operation,
	params map[string]any,
	idempotencyKey string,
	result any,
	onDispatched func(),
) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	switch operation.Class {
	case wirev2.Mutation:
		if idempotencyKey == "" {
			var err error
			idempotencyKey, err = c.idempotencyKey()
			if err != nil {
				return &TransportError{Operation: operation.Name, Err: err}
			}
		}
		if err := validateIdempotencyKey(idempotencyKey); err != nil {
			return err
		}
	default:
		if idempotencyKey != "" {
			return fmt.Errorf("%w: %s does not accept an idempotency key", ErrInvalidArgument, operation.Name)
		}
	}
	requestID := "go-" + strconv.FormatUint(c.nextRequestID.Add(1), 10)
	request := map[string]any{
		"protocol":  wirev2.Protocol,
		"type":      "request",
		"id":        requestID,
		"operation": operation.Name,
		"params":    params,
	}
	if idempotencyKey != "" {
		request[wirev2.FieldIdempotencyKey] = idempotencyKey
	}
	uncertain := func(err error) error {
		if operation.Class != wirev2.Mutation {
			return err
		}
		return &MutationTransportUncertainError{
			Operation: operation.Name, IdempotencyKey: idempotencyKey, Err: err,
		}
	}
	waiter := make(chan pendingResponse, 1)
	var cleanup *abandonedRequestCleanup
	if isCancelableWait(operation) {
		cleanup = &abandonedRequestCleanup{done: make(chan struct{})}
	}
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
	mayHaveSent, fullyWritten, err := c.write(
		ctx,
		operation.Name,
		request,
		onDispatched,
	)
	if err != nil {
		c.removePending(requestID, waiter)
		if mayHaveSent {
			// A partial JSON frame poisons the shared transport regardless of
			// operation. Only a complete frame leaves framing safe enough for
			// eligible pre-close stream cancellations.
			c.failWithCleanup(err, fullyWritten)
		}
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
		original := ctx.Err()
		if cleanup != nil {
			_ = c.cleanupAbandonedRequest(
				cleanup,
				operation,
				requestID,
				waiter,
			)
		} else {
			c.removePending(requestID, waiter)
		}
		return uncertain(original)
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

func isCancelableWait(operation wirev2.Operation) bool {
	return operation == wirev2.TerminalWait ||
		operation == wirev2.TerminalWaitExit
}

func (c *Client) cleanupAbandonedRequest(
	cleanup *abandonedRequestCleanup,
	operation wirev2.Operation,
	targetID string,
	targetWaiter chan pendingResponse,
) error {
	cleanup.once.Do(func() {
		deadline := time.Now().Add(abandonedRequestCleanupTimeout)
		c.beginRequestCleanup()
		cleanup.err = c.runAbandonedRequestCleanup(
			operation,
			targetID,
			targetWaiter,
			deadline,
		)
		if cleanup.err != nil {
			c.failWithCleanup(cleanup.err, false)
		}
		c.finishRequestCleanup()
		close(cleanup.done)
	})
	<-cleanup.done
	return cleanup.err
}

func (c *Client) runAbandonedRequestCleanup(
	operation wirev2.Operation,
	targetID string,
	targetWaiter chan pendingResponse,
	deadline time.Time,
) error {
	timer := time.NewTimer(time.Until(deadline))
	defer timer.Stop()
	select {
	case <-c.writer:
	case <-timer.C:
		return &TransportError{
			Operation: wirev2.RequestCancel.Name,
			Err:       context.DeadlineExceeded,
		}
	case <-c.done:
		return c.connectionError()
	}
	defer func() { c.writer <- struct{}{} }()

	if c.framingUnsafe {
		return &TransportError{
			Operation: wirev2.RequestCancel.Name,
			Err:       errors.New("connection framing is unsafe"),
		}
	}

	cancelID := "go-" + strconv.FormatUint(c.nextRequestID.Add(1), 10)
	cancelWaiter := make(chan pendingResponse, 1)
	c.mu.Lock()
	if c.closed {
		err := c.err
		c.mu.Unlock()
		if err == nil {
			err = ErrClosed
		}
		return err
	}
	c.pending[cancelID] = cancelWaiter
	c.mu.Unlock()
	defer c.removePending(cancelID, cancelWaiter)

	request := map[string]any{
		"protocol":  wirev2.Protocol,
		"type":      "request",
		"id":        cancelID,
		"operation": wirev2.RequestCancel.Name,
		"params": map[string]any{
			wirev2.FieldRequestID: targetID,
		},
	}
	if err := c.writeFrameLocked(
		wirev2.RequestCancel.Name,
		request,
		deadline,
	); err != nil {
		return err
	}

	cancelResponse, err := c.awaitPendingResponseUntil(
		cancelWaiter,
		deadline,
	)
	if err != nil {
		return err
	}
	canceled, err := decodeRequestCancelResponse(cancelResponse)
	if err != nil {
		return err
	}
	if canceled {
		if c.removePending(targetID, targetWaiter) {
			return nil
		}
		targetResponse, err := c.awaitPendingResponseUntil(
			targetWaiter,
			deadline,
		)
		if err != nil {
			return err
		}
		if err := validateAbandonedWaitResponse(
			operation,
			targetResponse,
		); err != nil {
			return err
		}
		return &ProtocolError{
			Message: "request.cancel returned canceled=true after the target responded",
		}
	}

	targetResponse, err := c.awaitPendingResponseUntil(
		targetWaiter,
		deadline,
	)
	if err != nil {
		return err
	}
	if err := validateAbandonedWaitResponse(
		operation,
		targetResponse,
	); err != nil {
		return err
	}
	return nil
}

func decodeRequestCancelResponse(response pendingResponse) (bool, error) {
	if response.err != nil {
		return false, response.err
	}
	if !response.envelope.OK {
		if response.envelope.Error == nil {
			return false, &ProtocolError{
				Message: "request.cancel failed without a structured error",
			}
		}
		return false, &ResourceError{
			Code:      response.envelope.Error.Code,
			Message:   response.envelope.Error.Message,
			Details:   cloneRaw(response.envelope.Error.Details),
			Retryable: response.envelope.Error.Retryable,
		}
	}
	var result requestCancelResultWire
	if err := strictDecode(response.envelope.Result, &result); err != nil {
		return false, &ProtocolError{
			Message: "cannot decode request.cancel result: " + err.Error(),
		}
	}
	if result.Canceled == nil {
		return false, &ProtocolError{
			Message: "request.cancel result omitted canceled",
		}
	}
	return *result.Canceled, nil
}

func validateAbandonedWaitResponse(
	operation wirev2.Operation,
	response pendingResponse,
) error {
	if response.err != nil {
		return response.err
	}
	if !response.envelope.OK {
		if response.envelope.Error == nil {
			return &ProtocolError{
				Message: operation.Name + " failed without a structured error",
			}
		}
		return nil
	}
	switch operation {
	case wirev2.TerminalWait:
		_, err := decodeValue[TerminalWaitResult](
			response.envelope.Result,
			"terminal wait result",
		)
		return err
	case wirev2.TerminalWaitExit:
		_, err := decodeTerminalWaitExitResult(response.envelope.Result)
		if err != nil {
			return &ProtocolError{
				Message: "cannot decode terminal wait exit result: " + err.Error(),
			}
		}
		return nil
	default:
		return &ProtocolError{
			Message: "request cancellation targeted unsupported operation " +
				operation.Name,
		}
	}
}

func (c *Client) awaitPendingResponseUntil(
	waiter <-chan pendingResponse,
	deadline time.Time,
) (pendingResponse, error) {
	remaining := time.Until(deadline)
	if remaining <= 0 {
		return pendingResponse{}, &TransportError{
			Operation: wirev2.RequestCancel.Name,
			Err:       context.DeadlineExceeded,
		}
	}
	timer := time.NewTimer(remaining)
	defer timer.Stop()
	select {
	case response, ok := <-waiter:
		if !ok {
			return pendingResponse{}, &ProtocolError{
				Message: "request response route closed without a response",
			}
		}
		return response, nil
	case <-timer.C:
		return pendingResponse{}, &TransportError{
			Operation: wirev2.RequestCancel.Name,
			Err:       context.DeadlineExceeded,
		}
	case <-c.done:
		select {
		case response, ok := <-waiter:
			if ok {
				return response, nil
			}
		default:
		}
		return pendingResponse{}, c.connectionError()
	}
}

func (c *Client) writeFrameLocked(
	operation string,
	value any,
	deadline time.Time,
) error {
	encoded, err := json.Marshal(value)
	if err != nil {
		return &ProtocolError{
			Message: "cannot encode " + operation + ": " + err.Error(),
		}
	}
	if len(encoded) > c.maxRequestBytes {
		return fmt.Errorf(
			"%w: %s request exceeds %d bytes",
			ErrInvalidArgument,
			operation,
			c.maxRequestBytes,
		)
	}
	if err := c.conn.SetWriteDeadline(deadline); err != nil {
		return &TransportError{Operation: operation, Err: err}
	}
	encoded = append(encoded, '\n')
	written := false
	for len(encoded) > 0 {
		count, writeErr := c.conn.Write(encoded)
		if count < 0 || count > len(encoded) {
			c.framingUnsafe = true
			return &TransportError{
				Operation: operation,
				Err:       errors.New("transport returned an invalid write count"),
			}
		}
		written = written || count > 0
		encoded = encoded[count:]
		if writeErr != nil {
			if len(encoded) > 0 {
				c.framingUnsafe = true
			}
			return &TransportError{Operation: operation, Err: writeErr}
		}
		if count == 0 {
			if written {
				c.framingUnsafe = true
			}
			return &TransportError{
				Operation: operation,
				Err:       io.ErrNoProgress,
			}
		}
	}
	return nil
}

func (c *Client) beginRequestCleanup() {
	c.requestCleanupMu.Lock()
	if c.requestCleanups == 0 {
		c.requestCleanupDone = make(chan struct{})
	}
	c.requestCleanups++
	c.requestCleanupMu.Unlock()
}

func (c *Client) finishRequestCleanup() {
	c.requestCleanupMu.Lock()
	if c.requestCleanups > 0 {
		c.requestCleanups--
	}
	if c.requestCleanups == 0 && c.requestCleanupDone != nil {
		close(c.requestCleanupDone)
		c.requestCleanupDone = nil
	}
	c.requestCleanupMu.Unlock()
}

func (c *Client) acquireWriter(ctx context.Context) error {
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-c.done:
			return c.connectionError()
		case <-c.writer:
		}

		c.requestCleanupMu.Lock()
		active := c.requestCleanups > 0
		cleanupDone := c.requestCleanupDone
		c.requestCleanupMu.Unlock()
		if !active {
			return nil
		}
		c.writer <- struct{}{}

		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-c.done:
			return c.connectionError()
		case <-cleanupDone:
		}
	}
}

func validateIdempotencyKey(value string) error {
	if !utf8.ValidString(value) {
		return fmt.Errorf("%w: mutation idempotency key must contain valid Unicode scalars", ErrInvalidArgument)
	}
	if len(value) < 1 || len(value) > 128 {
		return fmt.Errorf("%w: mutation idempotency key must contain 1 to 128 UTF-8 bytes", ErrInvalidArgument)
	}
	if strings.TrimFunc(value, unicode.IsSpace) == "" {
		return fmt.Errorf("%w: mutation idempotency key must contain a non-whitespace Unicode scalar", ErrInvalidArgument)
	}
	if strings.IndexFunc(value, unicode.IsControl) >= 0 {
		return fmt.Errorf("%w: mutation idempotency key must not contain Unicode control characters", ErrInvalidArgument)
	}
	return nil
}

func (c *Client) write(
	ctx context.Context,
	operation string,
	value any,
	onDispatched func(),
) (mayHaveSent bool, fullyWritten bool, resultErr error) {
	encoded, err := json.Marshal(value)
	if err != nil {
		return false, false, &ProtocolError{
			Message: "cannot encode " + operation + ": " + err.Error(),
		}
	}
	if len(encoded) > c.maxRequestBytes {
		return false, false, fmt.Errorf(
			"%w: %s request exceeds %d bytes",
			ErrInvalidArgument,
			operation,
			c.maxRequestBytes,
		)
	}
	if err := c.acquireWriter(ctx); err != nil {
		return false, false, err
	}
	defer func() {
		if mayHaveSent && !fullyWritten {
			// Publish poisoned framing before releasing writer ownership. A
			// cleanup already started by another failure must observe this.
			c.framingUnsafe = true
		}
		c.writer <- struct{}{}
	}()
	deadline := time.Now().Add(c.timeout)
	if contextDeadline, ok := ctx.Deadline(); ok && contextDeadline.Before(deadline) {
		deadline = contextDeadline
	}
	if err := c.conn.SetWriteDeadline(deadline); err != nil {
		return false, false, &TransportError{Operation: operation, Err: err}
	}
	encoded = append(encoded, '\n')
	written := false
	for len(encoded) > 0 {
		if err := ctx.Err(); err != nil {
			return written, false, err
		}
		count, err := c.conn.Write(encoded)
		if count < 0 || count > len(encoded) {
			c.framingUnsafe = true
			return written, false, &TransportError{
				Operation: operation,
				Err:       errors.New("transport returned an invalid write count"),
			}
		}
		written = written || count > 0
		if err != nil {
			encoded = encoded[count:]
			return written, len(encoded) == 0, &TransportError{
				Operation: operation,
				Err:       err,
			}
		}
		if count == 0 {
			return written, false, &TransportError{
				Operation: operation,
				Err:       io.ErrNoProgress,
			}
		}
		encoded = encoded[count:]
		if len(encoded) == 0 && onDispatched != nil {
			onDispatched()
		}
	}
	return true, true, nil
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
		if header.Protocol != wirev2.Protocol {
			c.fail(&ProtocolError{Message: "unexpected protocol " + header.Protocol})
			return
		}
		switch header.Type {
		case "response":
			response, err := decodeResponseEnvelope(line)
			if err != nil {
				c.fail(err)
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
			envelope, err := decodeStreamEnvelope(line, header.Type)
			if err != nil {
				c.fail(err)
				return
			}
			c.deliverStream(envelope, len(line))
		default:
			c.fail(&ProtocolError{Message: "unexpected envelope type " + header.Type})
			return
		}
	}
}

func decodeResponseEnvelope(raw json.RawMessage) (responseEnvelope, error) {
	var wire responseEnvelopeWire
	if err := strictDecode(raw, &wire); err != nil {
		return responseEnvelope{}, &ProtocolError{
			Message: "invalid response: " + err.Error(),
		}
	}
	if wire.Protocol == nil || *wire.Protocol != wirev2.Protocol ||
		wire.Type == nil || *wire.Type != "response" {
		return responseEnvelope{}, &ProtocolError{
			Message: "expected cmux.protocol/2 response envelope",
		}
	}
	if wire.ID == nil || utf8.RuneCountInString(*wire.ID) < 1 ||
		utf8.RuneCountInString(*wire.ID) > 128 {
		return responseEnvelope{}, &ProtocolError{
			Message: "response id must contain 1 to 128 characters",
		}
	}
	if wire.OK == nil {
		return responseEnvelope{}, &ProtocolError{
			Message: "response ok must be a boolean",
		}
	}
	response := responseEnvelope{
		Protocol: *wire.Protocol,
		Type:     *wire.Type,
		ID:       *wire.ID,
		OK:       *wire.OK,
	}
	if *wire.OK {
		if wire.Result == nil || wire.Error != nil {
			return responseEnvelope{}, &ProtocolError{
				Message: "successful response requires result and forbids error",
			}
		}
		response.Result = cloneRaw(wire.Result)
		return response, nil
	}
	if wire.Error == nil || wire.Result != nil {
		return responseEnvelope{}, &ProtocolError{
			Message: "failed response requires error and forbids result",
		}
	}
	structured, err := decodeStructuredError(wire.Error)
	if err != nil {
		return responseEnvelope{}, &ProtocolError{
			Message: "invalid response error: " + err.Error(),
		}
	}
	response.Error = structured
	return response, nil
}

func decodeStreamEnvelope(
	raw json.RawMessage,
	envelopeType string,
) (streamEnvelope, error) {
	switch envelopeType {
	case "stream_item":
		return decodeStreamItemEnvelope(raw)
	case "stream_end":
		return decodeStreamEndEnvelope(raw)
	default:
		return streamEnvelope{}, &ProtocolError{
			Message: "unexpected stream envelope type " + envelopeType,
		}
	}
}

func decodeStreamItemEnvelope(raw json.RawMessage) (streamEnvelope, error) {
	var wire streamItemEnvelopeWire
	if err := strictDecode(raw, &wire); err != nil {
		return streamEnvelope{}, &ProtocolError{
			Message: "invalid stream_item: " + err.Error(),
		}
	}
	if wire.Protocol == nil || *wire.Protocol != wirev2.Protocol ||
		wire.Type == nil || *wire.Type != "stream_item" {
		return streamEnvelope{}, &ProtocolError{
			Message: "expected cmux.protocol/2 stream_item envelope",
		}
	}
	streamID, err := decodeRequiredStreamID(wire.StreamID)
	if err != nil {
		return streamEnvelope{}, &ProtocolError{
			Message: "invalid stream_item stream_id: " + err.Error(),
		}
	}
	if wire.Sequence == nil {
		return streamEnvelope{}, &ProtocolError{
			Message: "stream_item sequence is required",
		}
	}
	var sequence Decimal
	if err := strictDecode(wire.Sequence, &sequence); err != nil {
		return streamEnvelope{}, &ProtocolError{
			Message: "invalid stream_item sequence: " + err.Error(),
		}
	}
	cursor, err := decodeOptionalCursor(wire.Cursor)
	if err != nil {
		return streamEnvelope{}, &ProtocolError{
			Message: "invalid stream_item cursor: " + err.Error(),
		}
	}
	if wire.Item == nil {
		return streamEnvelope{}, &ProtocolError{
			Message: "stream_item item is required",
		}
	}
	return streamEnvelope{
		Protocol: *wire.Protocol,
		Type:     *wire.Type,
		StreamID: streamID,
		Sequence: sequence,
		Cursor:   cursor,
		Item:     cloneRaw(wire.Item),
	}, nil
}

func decodeStreamEndEnvelope(raw json.RawMessage) (streamEnvelope, error) {
	var wire streamEndEnvelopeWire
	if err := strictDecode(raw, &wire); err != nil {
		return streamEnvelope{}, &ProtocolError{
			Message: "invalid stream_end: " + err.Error(),
		}
	}
	if wire.Protocol == nil || *wire.Protocol != wirev2.Protocol ||
		wire.Type == nil || *wire.Type != "stream_end" {
		return streamEnvelope{}, &ProtocolError{
			Message: "expected cmux.protocol/2 stream_end envelope",
		}
	}
	streamID, err := decodeRequiredStreamID(wire.StreamID)
	if err != nil {
		return streamEnvelope{}, &ProtocolError{
			Message: "invalid stream_end stream_id: " + err.Error(),
		}
	}
	if wire.Reason == nil || !validStreamEndReason(*wire.Reason) {
		return streamEnvelope{}, &ProtocolError{
			Message: "invalid stream_end reason",
		}
	}
	cursor, err := decodeOptionalCursor(wire.Cursor)
	if err != nil {
		return streamEnvelope{}, &ProtocolError{
			Message: "invalid stream_end cursor: " + err.Error(),
		}
	}
	var recovery string
	if wire.Recovery != nil {
		if bytes.Equal(bytes.TrimSpace(wire.Recovery), []byte("null")) {
			return streamEnvelope{}, &ProtocolError{
				Message: "invalid stream_end recovery: recovery must not be null",
			}
		}
		if err := strictDecode(wire.Recovery, &recovery); err != nil {
			return streamEnvelope{}, &ProtocolError{
				Message: "invalid stream_end recovery: " + err.Error(),
			}
		}
	}
	var structured *ResourceError
	if wire.Error != nil {
		structured, err = decodeStructuredError(wire.Error)
		if err != nil {
			return streamEnvelope{}, &ProtocolError{
				Message: "invalid stream_end error: " + err.Error(),
			}
		}
	}
	if (*wire.Reason == "error") != (structured != nil) {
		return streamEnvelope{}, &ProtocolError{
			Message: "stream_end error is required exactly when reason is error",
		}
	}
	return streamEnvelope{
		Protocol: *wire.Protocol,
		Type:     *wire.Type,
		StreamID: streamID,
		Reason:   *wire.Reason,
		Cursor:   cursor,
		Error:    structured,
		Recovery: recovery,
	}, nil
}

func decodeRequiredStreamID(raw json.RawMessage) (StreamID, error) {
	if raw == nil {
		return "", fmt.Errorf("field is required")
	}
	var streamID StreamID
	if err := strictDecode(raw, &streamID); err != nil {
		return "", err
	}
	return streamID, nil
}

func decodeOptionalCursor(raw json.RawMessage) (*Cursor, error) {
	if raw == nil {
		return nil, nil
	}
	if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		return nil, fmt.Errorf("cursor must not be null")
	}
	var cursor Cursor
	if err := strictDecode(raw, &cursor); err != nil {
		return nil, err
	}
	return &cursor, nil
}

func decodeStructuredError(raw json.RawMessage) (*ResourceError, error) {
	if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		return nil, fmt.Errorf("error must not be null")
	}
	var wire resourceErrorWire
	if err := strictDecode(raw, &wire); err != nil {
		return nil, err
	}
	if wire.Code == nil || wire.Message == nil || wire.Details == nil ||
		wire.Retryable == nil {
		return nil, fmt.Errorf(
			"error requires code, message, details, and retryable",
		)
	}
	return &ResourceError{
		Code:      *wire.Code,
		Message:   *wire.Message,
		Details:   cloneRaw(wire.Details),
		Retryable: *wire.Retryable,
	}, nil
}

func validStreamEndReason(reason string) bool {
	switch reason {
	case "completed", "canceled", "closed", "gap", "error":
		return true
	default:
		return false
	}
}

func (c *Client) deliverStream(envelope streamEnvelope, size int) {
	c.mu.Lock()
	route := c.streams[envelope.StreamID]
	if route == nil {
		c.mu.Unlock()
		return
	}
	cleanup := c.deliverStreamLocked(route, envelope, size)
	c.mu.Unlock()
	if cleanup {
		go c.cancelStreamBestEffort(route.cancelParams)
	}
}

// deliverStreamLocked returns whether the caller owns stream cleanup.
// c.mu must be held by the caller.
func (c *Client) deliverStreamLocked(
	route *streamRoute,
	envelope streamEnvelope,
	size int,
) bool {
	if envelope.Type == "stream_end" && !route.retainForExplicitCancel() {
		delete(c.streams, envelope.StreamID)
	}
	if route.deliver(streamMessage{envelope: envelope, size: size}) {
		return false
	}
	if envelope.Type == "stream_end" {
		return false
	}
	delete(c.streams, envelope.StreamID)
	route.overflow()
	return route.beginStreamCleanup()
}

func (c *Client) fail(err error) {
	c.failWithCleanup(err, true)
}

func (c *Client) failWithCleanup(err error, attemptCleanup bool) {
	c.failWithCleanupContext(context.Background(), err, attemptCleanup)
}

func (c *Client) failWithCleanupContext(ctx context.Context, err error, attemptCleanup bool) {
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
	if attemptCleanup {
		c.cancelFailedStreamOpens(ctx, streams)
	}
	_ = c.conn.Close()
	for _, waiter := range pending {
		waiter <- pendingResponse{err: err}
		close(waiter)
	}
	for _, route := range streams {
		route.finish(err)
	}
}

func (c *Client) cancelFailedStreamOpens(
	ctx context.Context,
	streams map[StreamID]*streamRoute,
) {
	deadline := time.Now().Add(failedStreamOpenCleanupTimeout)
	if contextDeadline, ok := ctx.Deadline(); ok && contextDeadline.Before(deadline) {
		deadline = contextDeadline
	}
	timer := time.NewTimer(time.Until(deadline))
	defer timer.Stop()
	select {
	case <-c.writer:
	case <-ctx.Done():
		return
	case <-timer.C:
		return
	}
	defer func() { c.writer <- struct{}{} }()
	if c.framingUnsafe {
		return
	}
	if err := c.conn.SetWriteDeadline(deadline); err != nil {
		return
	}
	for _, route := range streams {
		params, needed := route.failedOpenCancelParams()
		if !needed {
			continue
		}
		if err := c.writeUntrackedStreamCancel(params, deadline); err != nil {
			return
		}
	}
}

func (c *Client) writeUntrackedStreamCancel(
	params map[string]any,
	deadline time.Time,
) error {
	if err := c.conn.SetWriteDeadline(deadline); err != nil {
		return &TransportError{
			Operation: wirev2.StreamCancel.Name,
			Err:       err,
		}
	}
	request := map[string]any{
		"protocol":  wirev2.Protocol,
		"type":      "request",
		"id":        "go-" + strconv.FormatUint(c.nextRequestID.Add(1), 10),
		"operation": wirev2.StreamCancel.Name,
		"params":    params,
	}
	encoded, err := json.Marshal(request)
	if err != nil {
		return &ProtocolError{
			Message: "cannot encode stream.cancel request: " + err.Error(),
		}
	}
	encoded = append(encoded, '\n')
	for len(encoded) > 0 {
		count, writeErr := c.conn.Write(encoded)
		if count < 0 || count > len(encoded) {
			return &TransportError{
				Operation: wirev2.StreamCancel.Name,
				Err:       errors.New("transport returned an invalid write count"),
			}
		}
		if writeErr != nil {
			encoded = encoded[count:]
			return &TransportError{
				Operation: wirev2.StreamCancel.Name,
				Err:       writeErr,
			}
		}
		if count == 0 {
			return &TransportError{
				Operation: wirev2.StreamCancel.Name,
				Err:       io.ErrNoProgress,
			}
		}
		encoded = encoded[count:]
	}
	return nil
}

func (r *streamRoute) markOpenDispatched() {
	r.mu.Lock()
	r.openDispatched = true
	r.mu.Unlock()
}

func (r *streamRoute) markOpenAcknowledged() {
	r.mu.Lock()
	r.openAcknowledged = true
	r.mu.Unlock()
}

func (r *streamRoute) endedByServer() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.serverEnded
}

func (r *streamRoute) failedOpenCancelParams() (map[string]any, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.openDispatched || r.openAcknowledged || r.cleanupStarted {
		return nil, false
	}
	r.cleanupStarted = true
	return copyParams(r.cancelParams), true
}

func (r *streamRoute) beginFailedOpenCleanup() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.openDispatched || r.openAcknowledged || r.cleanupStarted {
		return false
	}
	r.cleanupStarted = true
	return true
}

func (r *streamRoute) beginStreamCleanup() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.cleanupStarted {
		return false
	}
	r.cleanupStarted = true
	return true
}

func (r *streamRoute) beginExplicitCancel(
	validateItem func(streamEnvelope) error,
) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.cleanupStarted {
		return false
	}
	r.cleanupStarted = true
	r.cancelItem = validateItem
	if r.cancelSignal == nil {
		r.cancelSignal = make(chan struct{}, 1)
	}
	return true
}

func (r *streamRoute) retainForExplicitCancel() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.cancelItem != nil
}

func (r *streamRoute) explicitCancelState() (*streamEnvelope, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	var end *streamEnvelope
	if r.cancelEnd != nil {
		value := *r.cancelEnd
		end = &value
	}
	return end, r.cancelErr
}

func (r *streamRoute) notifyExplicitCancelLocked() {
	select {
	case r.cancelSignal <- struct{}{}:
	default:
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
	if r.terminated {
		return false
	}
	if message.envelope.Type == "stream_end" {
		r.serverEnded = true
	}
	if r.cancelItem != nil {
		if r.cancelEnd != nil {
			var err error
			if message.envelope.Type == "stream_item" {
				err = r.cancelItem(message.envelope)
			}
			if err == nil {
				err = &ProtocolError{
					Message: "stream envelope followed stream_end during cancellation",
				}
			}
			r.cancelErr = err
			r.accepting = false
			r.terminated = true
			r.purgeLocked()
			r.notifyExplicitCancelLocked()
			return true
		}
		switch message.envelope.Type {
		case "stream_item":
			if err := r.cancelItem(message.envelope); err != nil {
				r.cancelErr = err
				r.accepting = false
				r.terminated = true
				r.purgeLocked()
				r.notifyExplicitCancelLocked()
			}
			return true
		case "stream_end":
			end := message.envelope
			r.cancelEnd = &end
			r.accepting = false
			r.notifyExplicitCancelLocked()
			return true
		}
	}
	if !r.accepting {
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

func (c *Client) removePending(
	id string,
	expected chan pendingResponse,
) bool {
	c.mu.Lock()
	current, exists := c.pending[id]
	if exists && current == expected {
		delete(c.pending, id)
	}
	c.mu.Unlock()
	return exists && current == expected
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
