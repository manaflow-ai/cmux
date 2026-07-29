package cmux

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"

	"github.com/manaflow-ai/cmux/cmux-tui/bindings/go/internal/wirev1"
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
// the server's stream.cancel response. Recv never returns an item after end.
type Stream[T any] struct {
	client *Client
	id     StreamID
	route  *streamRoute
	decode func(json.RawMessage) (T, error)

	mu           sync.Mutex
	finished     bool
	end          *StreamEndError
	cancelParams map[string]any
	cancelOnce   sync.Once
	cancelErr    error
}

func (s *Stream[T]) ID() StreamID { return s.id }

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
	value, err := s.decode(message.envelope.Item)
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
	s.mu.Unlock()
	s.cancelOnce.Do(func() {
		s.cancelErr = s.client.cancelStream(ctx, s.cancelParams)
		if s.cancelErr != nil {
			return
		}
		s.client.mu.Lock()
		delete(s.client.streams, s.id)
		s.client.mu.Unlock()
		end := s.route.cancelTerminal()
		s.markFinished(end)
	})
	return s.cancelErr
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
	_, err := readValue[EmptyResult](
		ctx,
		c,
		wirev1.StreamCancel,
		copyParams(params),
		"stream cancellation",
	)
	return err
}

func openStream[T any](
	ctx context.Context,
	client *Client,
	operation wirev1.Operation,
	params map[string]any,
	decode func(json.RawMessage) (T, error),
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
	for _, key := range []string{wirev1.FieldMachine, wirev1.FieldSession} {
		if value, ok := params[key]; ok {
			cancelParams[key] = value
		}
	}
	cancelParams["stream"] = id
	route.cancelParams = cancelParams
	params[wirev1.FieldStreamID] = id
	var raw json.RawMessage
	if err := client.do(ctx, operation, params, "", &raw); err != nil {
		client.mu.Lock()
		delete(client.streams, id)
		client.mu.Unlock()
		route.finish(ErrClosed)
		return nil, err
	}
	opened, err := decodeValue[StreamOpened](raw, operation.Name+" result")
	if err != nil {
		client.mu.Lock()
		delete(client.streams, id)
		client.mu.Unlock()
		route.finish(ErrClosed)
		return nil, err
	}
	if opened.StreamID != id {
		client.mu.Lock()
		delete(client.streams, id)
		client.mu.Unlock()
		route.finish(ErrClosed)
		return nil, &ProtocolError{
			Message: fmt.Sprintf(
				"%s returned stream %s for %s",
				operation.Name,
				opened.StreamID,
				id,
			),
		}
	}
	return &Stream[T]{
		client: client, id: id, route: route, decode: decode,
		cancelParams: cancelParams,
	}, nil
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
