package pane

import "io"

// Transport carries whole JSON text messages. Typed calls, subscriptions and
// auth sit on top and do not know which transport is underneath. WriteMessage
// is called by one goroutine at a time; ReadMessage only by Serve.
type Transport interface {
	ReadMessage() ([]byte, error)
	WriteMessage([]byte) error
	Close() error
}

type framed struct{ rw io.ReadWriteCloser }

// FramedTransport frames messages with the unix-socket wire: a 4-byte
// big-endian length prefix, at most MaxMessage bytes.
func FramedTransport(rw io.ReadWriteCloser) Transport { return framed{rw} }

func (f framed) ReadMessage() ([]byte, error) { return ReadFrame(f.rw) }
func (f framed) WriteMessage(b []byte) error  { return WriteFrame(f.rw, b) }
func (f framed) Close() error                 { return f.rw.Close() }
