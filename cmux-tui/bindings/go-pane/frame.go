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
	binary_ "encoding/binary"
	"errors"
	"fmt"
	"io"
	"unicode/utf8"
)

// MaxMessage is the largest message a peer may send in one frame. Larger data
// must use a byte stream.
const MaxMessage = 16 << 20

// binaryFlag is bit 31 of the unix frame header. It marks a binary message
// (a byte-stream data frame); the low 31 bits are the length. A text-only peer
// writes the plain length, and a reader that ignores the flag sees a length
// above MaxMessage and fails closed (Rust lane R1).
const binaryFlag = 1 << 31

// ErrFrameTooLarge reports a length above MaxMessage.
var ErrFrameTooLarge = errors.New("pane: frame exceeds 16 MiB")

// ErrNotUTF8 reports a text frame whose payload is not UTF-8. The frame has
// been consumed, so the stream is still in sync.
var ErrNotUTF8 = errors.New("pane: text frame is not UTF-8")

// ErrBinaryFrame is returned by ReadFrame when the next frame is binary.
var ErrBinaryFrame = errors.New("pane: unexpected binary frame")

// Frame is one unix-socket message: JSON text, or a binary data frame.
type Frame struct {
	Binary  bool
	Payload []byte
}

// ParseFrameHeader decodes the 4-byte header.
func ParseFrameHeader(h [4]byte) (binary bool, n uint32, err error) {
	v := binary_.BigEndian.Uint32(h[:])
	binary, n = v&binaryFlag != 0, v&^binaryFlag
	if n > MaxMessage {
		return binary, n, fmt.Errorf("%w (%d bytes)", ErrFrameTooLarge, n)
	}
	return binary, n, nil
}

func writeFrame(w io.Writer, payload []byte, flag uint32) error {
	if len(payload) > MaxMessage {
		return ErrFrameTooLarge
	}
	buf := make([]byte, 4+len(payload))
	binary_.BigEndian.PutUint32(buf, uint32(len(payload))|flag)
	copy(buf[4:], payload)
	_, err := w.Write(buf)
	return err
}

// WriteFrame writes one text message. The header and payload go out in one
// Write call so writers that lock per frame never interleave.
func WriteFrame(w io.Writer, text []byte) error { return writeFrame(w, text, 0) }

// WriteBinaryFrame writes one binary message (bit 31 set).
func WriteBinaryFrame(w io.Writer, payload []byte) error { return writeFrame(w, payload, binaryFlag) }

// ReadAnyFrame reads one frame. It refuses a length above MaxMessage before
// allocating. A clean EOF before the header returns io.EOF; EOF inside a
// frame returns io.ErrUnexpectedEOF. A text frame that is not UTF-8 returns
// ErrNotUTF8 after the frame is consumed.
func ReadAnyFrame(r io.Reader) (Frame, error) {
	var h [4]byte
	if _, err := io.ReadFull(r, h[:]); err != nil {
		return Frame{}, err
	}
	isBinary, n, err := ParseFrameHeader(h)
	if err != nil {
		return Frame{}, err
	}
	payload := make([]byte, n)
	if _, err := io.ReadFull(r, payload); err != nil {
		if errors.Is(err, io.EOF) {
			return Frame{}, io.ErrUnexpectedEOF
		}
		return Frame{}, err
	}
	if !isBinary && !utf8.Valid(payload) {
		return Frame{Payload: payload}, ErrNotUTF8
	}
	return Frame{Binary: isBinary, Payload: payload}, nil
}

// ReadFrame reads one text frame.
func ReadFrame(r io.Reader) ([]byte, error) {
	f, err := ReadAnyFrame(r)
	if err != nil {
		return nil, err
	}
	if f.Binary {
		return nil, ErrBinaryFrame
	}
	return f.Payload, nil
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
	binary_.BigEndian.PutUint32(b[0:4], f.Stream)
	binary_.BigEndian.PutUint32(b[4:8], f.Credit)
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
		Stream:  binary_.BigEndian.Uint32(b[0:4]),
		Credit:  binary_.BigEndian.Uint32(b[4:8]),
		Payload: append([]byte(nil), b[BinaryHeaderSize:]...),
	}, nil
}
