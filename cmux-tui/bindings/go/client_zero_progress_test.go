package cmux

import (
	"context"
	"errors"
	"io"
	"net"
	"testing"
)

type zeroProgressConn struct{ net.Conn }

func (zeroProgressConn) Write([]byte) (int, error) { return 0, nil }

func TestWriteReturnsNoProgressOnZeroByteWrite(t *testing.T) {
	clientSide, serverSide := net.Pipe()
	defer func() { _ = clientSide.Close() }()
	defer func() { _ = serverSide.Close() }()

	client := &Client{
		conn:            zeroProgressConn{Conn: clientSide},
		timeout:         0,
		maxRequestBytes: MaxRequestBytes,
		writer:          make(chan struct{}, 1),
		done:            make(chan struct{}),
	}
	client.writer <- struct{}{}

	_, _, err := client.write(context.Background(), "test", map[string]string{"value": "payload"}, nil)
	var transportErr *TransportError
	if !errors.As(err, &transportErr) {
		t.Fatalf("error = %T %v, want TransportError", err, err)
	}
	if !errors.Is(transportErr, io.ErrNoProgress) {
		t.Fatalf("error = %v, want io.ErrNoProgress", transportErr)
	}
}
