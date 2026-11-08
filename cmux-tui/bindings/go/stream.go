package cmux

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/manaflow-ai/cmux/cmux-tui/bindings/go/internal/wirev2"
)

type StreamItem[T any] struct {
	Sequence Decimal
	Cursor   *Cursor
	Value    T
}

type StreamEndError struct {
	Reason        string
	Cursor        *Cursor
	ResourceError *ResourceError
	Recovery      string
}

func (e *StreamEndError) Error() string {
	if e.ResourceError != nil {
		return fmt.Sprintf("cmux stream ended (%s): %s", e.Reason, e.ResourceError)
	}
	return "cmux stream ended: " + e.Reason
}

// Stream is a cancellable typed stream. Cancel is idempotent and waits for
// both the server's stream.cancel response and canceled stream end. Recv never
// returns an item after end.
// The context passed to the stream-opening method governs only the open
// handshake. After acknowledgement, each Recv or Cancel context governs that
// operation without imposing an idle stream deadline.
type Stream[T any] struct {
	client          *Client
	id              StreamID
	attachmentLease string
	route           *streamRoute
	decode          func(json.RawMessage, *Cursor) (T, error)

	mu            sync.Mutex
	finished      bool
	end           *StreamEndError
	cancelParams  map[string]any
	cancelStarted bool
	cancelDone    chan struct{}
	cancelErr     error
}

func (s *Stream[T]) ID() StreamID { return s.id }

// AttachmentLease returns the lease required to size or release a terminal or
// browser attachment. Other stream kinds return false.
func (s *Stream[T]) AttachmentLease() (string, bool) {
	return s.attachmentLease, s.attachmentLease != ""
}

func (s *Stream[T]) Recv(ctx context.Context) (StreamItem[T], error) {
	var zero StreamItem[T]
	if s.isFinished() {
		return zero, ErrClosed
	}
	if err := ctx.Err(); err != nil {
		return zero, err
	}
	select {
	case message := <-s.route.messages:
		return s.consume(message)
	default:
	}
	select {
	case <-ctx.Done():
		return zero, ctx.Err()
	case message := <-s.route.messages:
		return s.consume(message)
	case <-s.client.done:
		// Preserve a terminal envelope that raced with transport shutdown.
		select {
		case message := <-s.route.messages:
			return s.consume(message)
		default:
			return zero, s.client.connectionError()
		}
	}
}

func (s *Stream[T]) consume(message streamMessage) (StreamItem[T], error) {
	var zero StreamItem[T]
	s.route.consumed(message.size)
	if message.err != nil {
		var end *StreamEndError
		if candidate, ok := message.err.(*StreamEndError); ok {
			end = candidate
		}
		s.markFinished(end)
		return zero, message.err
	}
	if message.envelope.Type == "stream_end" {
		end := streamEndFromEnvelope(message.envelope)
		s.markFinished(end)
		return zero, end
	}
	value, err := s.decode(message.envelope.Item, message.envelope.Cursor)
	if err != nil {
		return zero, err
	}
	return StreamItem[T]{
		Sequence: message.envelope.Sequence,
		Cursor:   message.envelope.Cursor,
		Value:    value,
	}, nil
}

func (s *Stream[T]) Cancel(ctx context.Context) error {
	s.mu.Lock()
	if s.finished {
		s.mu.Unlock()
		return nil
	}
	if s.cancelStarted {
		done := s.cancelDone
		s.mu.Unlock()
		<-done
		s.mu.Lock()
		err := s.cancelErr
		s.mu.Unlock()
		return err
	}
	if err := ctx.Err(); err != nil {
		s.mu.Unlock()
		return err
	}
	s.cancelStarted = true
	s.cancelDone = make(chan struct{})
	s.mu.Unlock()

	cancelErr := s.cancel(ctx)
	s.mu.Lock()
	s.cancelErr = cancelErr
	close(s.cancelDone)
	s.mu.Unlock()
	return cancelErr
}

func (s *Stream[T]) cancel(ctx context.Context) error {
	s.client.mu.Lock()
	ownsCleanup := s.route.beginExplicitCancel(func(envelope streamEnvelope) error {
		_, err := s.decode(envelope.Item, envelope.Cursor)
		return err
	})
	if !ownsCleanup {
		delete(s.client.streams, s.id)
	}
	s.client.mu.Unlock()
	if !ownsCleanup {
		end := s.route.cancelTerminal()
		s.markFinished(end)
		return nil
	}
	deadline := time.Now().Add(s.client.timeout)
	if contextDeadline, ok := ctx.Deadline(); ok &&
		contextDeadline.Before(deadline) {
		deadline = contextDeadline
	}
	cancelContext, finishCancel := context.WithDeadline(ctx, deadline)
	defer finishCancel()
	end, err := s.cancelAndAwait(cancelContext)
	if err != nil {
		s.client.fail(err)
		return err
	}
	s.client.mu.Lock()
	delete(s.client.streams, s.id)
	s.client.mu.Unlock()
	s.markFinished(end)
	return nil
}

func (s *Stream[T]) Close(ctx context.Context) error { return s.Cancel(ctx) }

// End returns the terminal server envelope after it has been observed. It is
// available after Recv returns a StreamEndError and after successful Cancel.
func (s *Stream[T]) End() *StreamEndError {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.end
}

func (s *Stream[T]) markFinished(end *StreamEndError) {
	s.mu.Lock()
	s.finished = true
	if end != nil {
		s.end = end
	}
	s.mu.Unlock()
}

func (s *Stream[T]) isFinished() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.finished
}

func (c *Client) cancelStream(ctx context.Context, params map[string]any) error {
	var raw json.RawMessage
	if err := c.do(
		ctx,
		wirev2.StreamCancel,
		copyParams(params),
		"",
		&raw,
	); err != nil {
		return err
	}
	return decodeEmptyResult(raw, "stream cancellation")
}

func decodeEmptyResult(raw json.RawMessage, label string) error {
	if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		return &ProtocolError{Message: "cannot decode " + label + ": expected an empty object"}
	}
	_, err := decodeValue[EmptyResult](raw, label)
	return err
}

func (s *Stream[T]) cancelAndAwait(
	ctx context.Context,
) (*StreamEndError, error) {
	response := make(chan error, 1)
	go func() {
		response <- s.client.cancelStream(ctx, s.cancelParams)
	}()
	var responseReceived bool
	var end *StreamEndError
	var stateEndObserved bool
	var transportErr error
	recordMessage := func(message streamMessage) error {
		candidate, done, err := s.consumeCancelMessage(message)
		if err != nil {
			if errors.Is(err, ErrTransport) {
				transportErr = err
				return nil
			}
			return err
		}
		if !done {
			return nil
		}
		if end != nil {
			return &ProtocolError{
				Message: "stream cancellation received multiple stream ends",
			}
		}
		end = candidate
		return nil
	}
	refreshState := func() error {
		stateEnd, stateErr := s.route.explicitCancelState()
		if stateErr != nil {
			return stateErr
		}
		if stateEnd == nil || stateEndObserved {
			return nil
		}
		stateEndObserved = true
		return recordMessage(streamMessage{envelope: *stateEnd})
	}
	for {
		if err := refreshState(); err != nil {
			return nil, err
		}
		if responseReceived && end != nil {
			for {
				select {
				case message := <-s.route.messages:
					if err := recordMessage(message); err != nil {
						return nil, err
					}
				default:
					if err := refreshState(); err != nil {
						return nil, err
					}
					return end, nil
				}
			}
		}
		if responseReceived && transportErr != nil {
			return nil, transportErr
		}
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case err := <-response:
			if err != nil {
				return nil, err
			}
			responseReceived = true
			response = nil
		case message := <-s.route.messages:
			if err := recordMessage(message); err != nil {
				return nil, err
			}
		case <-s.route.cancelSignal:
		}
	}
}

func (s *Stream[T]) consumeCancelMessage(
	message streamMessage,
) (*StreamEndError, bool, error) {
	s.route.consumed(message.size)
	if message.err != nil {
		return nil, false, message.err
	}
	switch message.envelope.Type {
	case "stream_item":
		if message.envelope.StreamID != s.id {
			return nil, false, &ProtocolError{
				Message: "stream cancellation received a mismatched stream item",
			}
		}
		if _, err := s.decode(message.envelope.Item, message.envelope.Cursor); err != nil {
			return nil, false, err
		}
		return nil, false, nil
	case "stream_end":
		if message.envelope.StreamID != s.id {
			return nil, false, &ProtocolError{
				Message: "stream cancellation received a mismatched stream end",
			}
		}
		if message.envelope.Reason != "canceled" {
			return nil, false, &ProtocolError{
				Message: fmt.Sprintf(
					"stream cancellation ended with %s, expected canceled",
					message.envelope.Reason,
				),
			}
		}
		return streamEndFromEnvelope(message.envelope), true, nil
	default:
		return nil, false, &ProtocolError{
			Message: "stream cancellation received an unexpected envelope",
		}
	}
}

func openStream[T any](
	ctx context.Context,
	client *Client,
	operation wirev2.Operation,
	params map[string]any,
	decode func(json.RawMessage) (T, error),
) (*Stream[T], error) {
	return openDecodedStream(
		ctx,
		client,
		operation,
		params,
		func(raw json.RawMessage, _ *Cursor) (T, error) { return decode(raw) },
	)
}

func openDecodedStream[T any](
	ctx context.Context,
	client *Client,
	operation wirev2.Operation,
	params map[string]any,
	decode func(json.RawMessage, *Cursor) (T, error),
) (*Stream[T], error) {
	id, err := newStreamID()
	if err != nil {
		return nil, &TransportError{Operation: operation.Name, Err: err}
	}
	// One control message is reserved beyond the 256 data-message bound.
	route := &streamRoute{
		messages:  make(chan streamMessage, MaxStreamQueueMessages+1),
		accepting: true,
	}
	client.mu.Lock()
	if client.closed {
		client.mu.Unlock()
		return nil, client.connectionError()
	}
	client.streams[id] = route
	client.mu.Unlock()
	params = copyParams(params)
	cancelParams := make(map[string]any, 3)
	for _, key := range []string{wirev2.FieldMachine, wirev2.FieldSession} {
		if value, ok := params[key]; ok {
			cancelParams[key] = value
		}
	}
	cancelParams["stream"] = id
	route.cancelParams = cancelParams
	params[wirev2.FieldStreamID] = id
	failOpen := func(openError error) (*Stream[T], error) {
		client.cleanupFailedStreamOpen(id, route, openError)
		return nil, openError
	}
	var raw json.RawMessage
	if err := client.doTracked(
		ctx,
		operation,
		params,
		"",
		&raw,
		func() {
			route.markOpenDispatched()
		},
	); err != nil {
		var rejected *ResourceError
		if errors.As(err, &rejected) {
			client.mu.Lock()
			if client.streams[id] == route {
				delete(client.streams, id)
			}
			client.mu.Unlock()
			route.finish(err)
			return nil, err
		}
		return failOpen(err)
	}
	openedID := StreamID("")
	attachmentLease := ""
	if operation.Name == wirev2.TerminalAttach.Name || operation.Name == wirev2.BrowserAttach.Name {
		opened, decodeErr := decodeValue[ViewAttachmentStreamOpened](raw, operation.Name+" result")
		if decodeErr != nil {
			return failOpen(decodeErr)
		}
		openedID = opened.StreamID
		attachmentLease = opened.AttachmentLease
		if len(attachmentLease) < 1 || len(attachmentLease) > 128 {
			return failOpen(&ProtocolError{Message: operation.Name + " attachment_lease must contain 1 to 128 bytes"})
		}
	} else {
		opened, decodeErr := decodeValue[StreamOpened](raw, operation.Name+" result")
		if decodeErr != nil {
			return failOpen(decodeErr)
		}
		openedID = opened.StreamID
	}
	if openedID != id {
		return failOpen(&ProtocolError{
			Message: fmt.Sprintf(
				"%s returned stream %s for %s",
				operation.Name,
				openedID,
				id,
			),
		})
	}
	client.mu.Lock()
	// Preserve a complete stream when its terminal envelope raced with EOF.
	if client.closed && !route.endedByServer() {
		openError := client.err
		if openError == nil {
			openError = ErrClosed
		}
		client.mu.Unlock()
		route.finish(openError)
		return nil, openError
	}
	route.markOpenAcknowledged()
	client.mu.Unlock()
	return &Stream[T]{
		client: client, id: id, route: route, decode: decode,
		attachmentLease: attachmentLease,
		cancelParams:    cancelParams,
	}, nil
}

func (c *Client) cancelStreamBestEffort(params map[string]any) {
	ctx, cancel := context.WithTimeout(
		context.Background(),
		failedStreamOpenCleanupTimeout,
	)
	defer cancel()
	if err := c.cancelStream(ctx, params); err != nil {
		c.fail(err)
	}
}

func (c *Client) cleanupFailedStreamOpen(
	id StreamID,
	route *streamRoute,
	openError error,
) {
	c.mu.Lock()
	route.finish(openError)
	if c.closed || c.streams[id] != route {
		c.mu.Unlock()
		return
	}
	if !route.beginFailedOpenCleanup() {
		delete(c.streams, id)
		c.mu.Unlock()
		return
	}
	c.mu.Unlock()

	ctx, cancel := context.WithTimeout(
		context.Background(),
		failedStreamOpenCleanupTimeout,
	)
	defer cancel()
	var raw json.RawMessage
	cleanupErr := c.do(
		ctx,
		wirev2.StreamCancel,
		copyParams(route.cancelParams),
		"",
		&raw,
	)
	if cleanupErr == nil {
		cleanupErr = decodeEmptyResult(
			raw,
			"failed stream-open cancellation",
		)
	}
	c.mu.Lock()
	if c.streams[id] == route {
		delete(c.streams, id)
	}
	c.mu.Unlock()
	if cleanupErr != nil {
		c.fail(&TransportError{
			Operation: wirev2.StreamCancel.Name,
			Err:       cleanupErr,
		})
	}
}

func streamEndFromEnvelope(envelope streamEnvelope) *StreamEndError {
	var resourceError *ResourceError
	if envelope.Error != nil {
		resourceError = &ResourceError{
			Code:      envelope.Error.Code,
			Message:   envelope.Error.Message,
			Details:   cloneRaw(envelope.Error.Details),
			Retryable: envelope.Error.Retryable,
		}
	}
	return &StreamEndError{
		Reason:        envelope.Reason,
		Cursor:        envelope.Cursor,
		ResourceError: resourceError,
		Recovery:      envelope.Recovery,
	}
}

func copyParams(params map[string]any) map[string]any {
	result := make(map[string]any, len(params)+1)
	for key, value := range params {
		result[key] = value
	}
	return result
}
