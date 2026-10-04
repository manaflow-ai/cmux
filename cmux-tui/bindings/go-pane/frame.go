// Package pane is the Go runtime for the cmux pane protocol (draft v0).
//
// It implements the unix-socket wire (4-byte big-endian length prefix, 16 MiB
// maximum), the JSON envelope, Ed25519 capability token verification, the
// provider admission handshake with the router, and a symmetric connection
// that dispatches incoming calls concurrently, answers them out of order,
// honors cancel, and serves subscriptions.
//
// Typed clients, handler interfaces, and params validators are generated from
// the pane-protocol IR by cmux-tui/bindings/codegen/pane (see README.md).
package pane

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
)

// MaxMessage is the largest message a peer may send in one frame. Larger data
// must use a byte stream.
const MaxMessage = 16 << 20

// ErrFrameTooLarge reports a length prefix above MaxMessage.
var ErrFrameTooLarge = errors.New("pane: frame exceeds 16 MiB")

// ErrEmptyFrame reports a zero length prefix. Every message is a non-empty
// JSON document, so an empty frame is a protocol error.
var ErrEmptyFrame = errors.New("pane: empty frame")

// WriteFrame writes one length-prefixed message. The prefix and payload are
// written with a single Write call so concurrent writers that hold a lock per
// frame never interleave.
func WriteFrame(w io.Writer, payload []byte) error {
	if len(payload) == 0 {
		return ErrEmptyFrame
	}
	if len(payload) > MaxMessage {
		return ErrFrameTooLarge
	}
	buf := make([]byte, 4+len(payload))
	binary.BigEndian.PutUint32(buf, uint32(len(payload)))
	copy(buf[4:], payload)
	_, err := w.Write(buf)
	return err
}

// ReadFrame reads one length-prefixed message. It refuses a prefix above
// MaxMessage before allocating, so a hostile peer cannot force a large
// allocation. A clean EOF before the prefix returns io.EOF; EOF inside a frame
// returns io.ErrUnexpectedEOF.
func ReadFrame(r io.Reader) ([]byte, error) {
	var prefix [4]byte
	if _, err := io.ReadFull(r, prefix[:]); err != nil {
		return nil, err
	}
	n := binary.BigEndian.Uint32(prefix[:])
	if n == 0 {
		return nil, ErrEmptyFrame
	}
	if n > MaxMessage {
		return nil, fmt.Errorf("%w (%d bytes)", ErrFrameTooLarge, n)
	}
	payload := make([]byte, n)
	if _, err := io.ReadFull(r, payload); err != nil {
		if errors.Is(err, io.EOF) {
			return nil, io.ErrUnexpectedEOF
		}
		return nil, err
	}
	return payload, nil
}

// BinaryHeaderSize is the byte-stream frame header: u32 stream id and u32
// credit, both big-endian.
const BinaryHeaderSize = 8

// BinaryFrame is one byte-stream frame. Byte streams themselves are not
// implemented yet; this codec exists so the wire layout is shared and tested.
type BinaryFrame struct {
	Stream  uint32
	Credit  uint32
	Payload []byte
}

// EncodeBinaryFrame lays out [u32 stream BE][u32 credit BE][payload].
func EncodeBinaryFrame(f BinaryFrame) ([]byte, error) {
	if BinaryHeaderSize+len(f.Payload) > MaxMessage {
		return nil, ErrFrameTooLarge
	}
	b := make([]byte, BinaryHeaderSize, BinaryHeaderSize+len(f.Payload))
	binary.BigEndian.PutUint32(b[0:4], f.Stream)
	binary.BigEndian.PutUint32(b[4:8], f.Credit)
	return append(b, f.Payload...), nil
}

// DecodeBinaryFrame parses a byte-stream frame.
func DecodeBinaryFrame(b []byte) (BinaryFrame, error) {
	if len(b) < BinaryHeaderSize {
		return BinaryFrame{}, fmt.Errorf("pane: binary frame shorter than %d bytes", BinaryHeaderSize)
	}
	if len(b) > MaxMessage {
		return BinaryFrame{}, ErrFrameTooLarge
	}
	return BinaryFrame{
		Stream:  binary.BigEndian.Uint32(b[0:4]),
		Credit:  binary.BigEndian.Uint32(b[4:8]),
		Payload: append([]byte(nil), b[BinaryHeaderSize:]...),
	}, nil
}
