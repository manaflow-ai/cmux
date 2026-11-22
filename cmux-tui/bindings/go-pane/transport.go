package pane

import "io"

// Transport carries whole JSON text messages. Typed calls, subscriptions and
// auth sit on top and do not know which transport is underneath. WriteMessage
// is called by one goroutine at a time; ReadMessage only by Serve.
type Transport interface {
	// ReadMessage returns the next text message, or a binary data frame
	// with Binary set. ErrNotUTF8 is not fatal; other errors end the
	// connection.
	ReadMessage() (Frame, error)
	WriteMessage([]byte) error
	Close() error
}

// refusingCloser is implemented by transports with a close code (WebSocket
// closes with 4001 after an auth refusal).
type refusingCloser interface{ CloseAuthRefused() error }

type framed struct{ rw io.ReadWriteCloser }

// FramedTransport frames messages with the unix-socket wire: a 4-byte
// big-endian length prefix, at most MaxMessage bytes.
func FramedTransport(rw io.ReadWriteCloser) Transport { return framed{rw} }

func (f framed) ReadMessage() (Frame, error) { return ReadAnyFrame(f.rw) }
func (f framed) WriteMessage(b []byte) error { return WriteFrame(f.rw, b) }
func (f framed) Close() error                { return f.rw.Close() }
