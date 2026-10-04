package pane

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"strings"
	"testing"
)

func TestFrameRoundTrip(t *testing.T) {
	var buf bytes.Buffer
	msgs := []string{`{"t":"cancel","id":1}`, `{"t":"unsub","sub":2}`}
	for _, m := range msgs {
		if err := WriteFrame(&buf, []byte(m)); err != nil {
			t.Fatal(err)
		}
	}
	if got := buf.Bytes()[:4]; !bytes.Equal(got, []byte{0, 0, 0, byte(len(msgs[0]))}) {
		t.Fatalf("prefix is not 4-byte big-endian length: %v", got)
	}
	for _, want := range msgs {
		got, err := ReadFrame(&buf)
		if err != nil {
			t.Fatal(err)
		}
		if string(got) != want {
			t.Fatalf("got %q want %q", got, want)
		}
	}
	if _, err := ReadFrame(&buf); err != io.EOF {
		t.Fatalf("clean end: got %v want io.EOF", err)
	}
}

func TestFrameMaxSize(t *testing.T) {
	big := bytes.Repeat([]byte("a"), MaxMessage)
	var buf bytes.Buffer
	if err := WriteFrame(&buf, big); err != nil {
		t.Fatalf("exactly 16 MiB must be allowed: %v", err)
	}
	got, err := ReadFrame(&buf)
	if err != nil || len(got) != MaxMessage {
		t.Fatalf("read max frame: len %d err %v", len(got), err)
	}
	if err := WriteFrame(io.Discard, append(big, 'b')); !errors.Is(err, ErrFrameTooLarge) {
		t.Fatalf("write 16 MiB + 1: got %v", err)
	}
	// A hostile prefix is refused before the payload is read or allocated.
	var prefix [4]byte
	binary.BigEndian.PutUint32(prefix[:], MaxMessage+1)
	if _, err := ReadFrame(bytes.NewReader(prefix[:])); !errors.Is(err, ErrFrameTooLarge) {
		t.Fatalf("read 16 MiB + 1 prefix: got %v", err)
	}
	binary.BigEndian.PutUint32(prefix[:], 0xFFFFFFFF)
	if _, err := ReadFrame(bytes.NewReader(prefix[:])); !errors.Is(err, ErrFrameTooLarge) {
		t.Fatalf("read 4 GiB prefix: got %v", err)
	}
}

func TestFrameEmptyBinaryAndTruncated(t *testing.T) {
	// An empty text frame is valid framing (the envelope decoder rejects it).
	if b, err := ReadFrame(bytes.NewReader([]byte{0, 0, 0, 0})); err != nil || len(b) != 0 {
		t.Fatalf("read empty: %v", err)
	}
	var buf bytes.Buffer
	_ = WriteBinaryFrame(&buf, []byte{1, 2})
	if got := buf.Bytes(); !bytes.Equal(got, []byte{0x80, 0, 0, 2, 1, 2}) {
		t.Fatalf("binary header %v", got)
	}
	f, err := ReadAnyFrame(bytes.NewReader(buf.Bytes()))
	if err != nil || !f.Binary || !bytes.Equal(f.Payload, []byte{1, 2}) {
		t.Fatalf("read binary: %+v %v", f, err)
	}
	if _, err := ReadFrame(bytes.NewReader(buf.Bytes())); !errors.Is(err, ErrBinaryFrame) {
		t.Fatalf("ReadFrame on binary: %v", err)
	}
	if _, err := ReadAnyFrame(bytes.NewReader([]byte{0, 0, 0, 2, 0xC3, 0x28})); !errors.Is(err, ErrNotUTF8) {
		t.Fatalf("non-UTF-8 text: %v", err)
	}
	if _, err := ReadFrame(bytes.NewReader([]byte{0, 0, 0, 5, 'a', 'b'})); err != io.ErrUnexpectedEOF {
		t.Fatalf("truncated payload: %v", err)
	}
	if _, err := ReadFrame(strings.NewReader("\x00\x00")); err != io.ErrUnexpectedEOF {
		t.Fatalf("truncated prefix: %v", err)
	}
}

func TestBinaryFrameLayout(t *testing.T) {
	b, err := EncodeBinaryFrame(BinaryFrame{Stream: 3, Credit: 65536, Payload: []byte("hi")})
	if err != nil {
		t.Fatal(err)
	}
	if want := []byte{0, 0, 0, 3, 0, 1, 0, 0, 'h', 'i'}; !bytes.Equal(b, want) {
		t.Fatalf("got %v", b)
	}
	f, err := DecodeBinaryFrame(b)
	if err != nil || f.Stream != 3 || f.Credit != 65536 || string(f.Payload) != "hi" {
		t.Fatalf("decode %+v %v", f, err)
	}
	if _, err := DecodeBinaryFrame(b[:7]); err == nil {
		t.Fatal("short frame accepted")
	}
}
