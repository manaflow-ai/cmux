package pane

import (
	"bufio"
	"context"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

// This is a minimal RFC 6455 server, enough for pages to reach a provider
// directly: text messages, fragmentation, ping/pong and close. Binary frames
// (byte streams) are refused until streams are implemented.

const wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

const (
	wsContinuation = 0x0
	wsText         = 0x1
	wsBinary       = 0x2
	wsClose        = 0x8
	wsPing         = 0x9
	wsPong         = 0xA
)

// ErrWebSocketProtocol reports a peer that broke RFC 6455.
var ErrWebSocketProtocol = errors.New("pane: websocket protocol error")

type wsConn struct {
	nc  net.Conn
	br  *bufio.Reader
	wmu sync.Mutex
}

func (w *wsConn) Close() error {
	w.writeFrame(wsClose, []byte{0x03, 0xE8}) // 1000 normal closure, best effort
	return w.nc.Close()
}

func (w *wsConn) WriteMessage(b []byte) error {
	if len(b) > MaxMessage {
		return ErrFrameTooLarge
	}
	return w.writeFrame(wsText, b)
}

func (w *wsConn) writeFrame(opcode byte, payload []byte) error {
	hdr := make([]byte, 0, 10+len(payload))
	hdr = append(hdr, 0x80|opcode)
	switch n := len(payload); {
	case n < 126:
		hdr = append(hdr, byte(n))
	case n <= 0xFFFF:
		hdr = append(hdr, 126, byte(n>>8), byte(n))
	default:
		hdr = append(hdr, 127)
		hdr = binary.BigEndian.AppendUint64(hdr, uint64(n))
	}
	hdr = append(hdr, payload...)
	w.wmu.Lock()
	defer w.wmu.Unlock()
	_, err := w.nc.Write(hdr)
	return err
}

func (w *wsConn) readFrame() (fin bool, opcode byte, payload []byte, err error) {
	var h [2]byte
	if _, err = io.ReadFull(w.br, h[:]); err != nil {
		return
	}
	fin, opcode = h[0]&0x80 != 0, h[0]&0x0F
	if h[0]&0x70 != 0 {
		return false, 0, nil, fmt.Errorf("%w: reserved bits set", ErrWebSocketProtocol)
	}
	if h[1]&0x80 == 0 {
		return false, 0, nil, fmt.Errorf("%w: client frame is not masked", ErrWebSocketProtocol)
	}
	n := uint64(h[1] & 0x7F)
	switch n {
	case 126:
		var b [2]byte
		if _, err = io.ReadFull(w.br, b[:]); err != nil {
			return
		}
		n = uint64(binary.BigEndian.Uint16(b[:]))
	case 127:
		var b [8]byte
		if _, err = io.ReadFull(w.br, b[:]); err != nil {
			return
		}
		n = binary.BigEndian.Uint64(b[:])
	}
	if opcode >= wsClose && (n > 125 || !fin) {
		return false, 0, nil, fmt.Errorf("%w: bad control frame", ErrWebSocketProtocol)
	}
	if n > MaxMessage {
		return false, 0, nil, ErrFrameTooLarge
	}
	var mask [4]byte
	if _, err = io.ReadFull(w.br, mask[:]); err != nil {
		return
	}
	payload = make([]byte, n)
	if _, err = io.ReadFull(w.br, payload); err != nil {
		return
	}
	for i := range payload {
		payload[i] ^= mask[i%4]
	}
	return fin, opcode, payload, nil
}

func (w *wsConn) ReadMessage() ([]byte, error) {
	var msg []byte
	var kind byte
	started := false
	for {
		fin, opcode, payload, err := w.readFrame()
		if err != nil {
			if errors.Is(err, io.EOF) {
				return nil, io.ErrUnexpectedEOF
			}
			return nil, err
		}
		switch opcode {
		case wsClose:
			code := payload
			if len(code) > 2 {
				code = code[:2]
			}
			w.writeFrame(wsClose, code)
			return nil, io.EOF
		case wsPing:
			if err := w.writeFrame(wsPong, payload); err != nil {
				return nil, err
			}
			continue
		case wsPong:
			continue
		case wsText, wsBinary:
			if started {
				return nil, fmt.Errorf("%w: new message inside a fragmented one", ErrWebSocketProtocol)
			}
			started, kind, msg = true, opcode, payload
		case wsContinuation:
			if !started {
				return nil, fmt.Errorf("%w: continuation without a message", ErrWebSocketProtocol)
			}
			if len(msg)+len(payload) > MaxMessage {
				return nil, ErrFrameTooLarge
			}
			msg = append(msg, payload...)
		default:
			return nil, fmt.Errorf("%w: opcode %d", ErrWebSocketProtocol, opcode)
		}
		if !fin {
			continue
		}
		if kind == wsBinary {
			return nil, fmt.Errorf("pane: binary frames (byte streams) are not supported")
		}
		if !utf8.Valid(msg) {
			return nil, fmt.Errorf("%w: text message is not UTF-8", ErrWebSocketProtocol)
		}
		return msg, nil
	}
}

// WebSocketOptions configure ServeWebSocket.
type WebSocketOptions struct {
	// AllowedOrigins, when non-empty, lists the page origins that may
	// connect. The token's origin claim must equal the Origin header either
	// way.
	AllowedOrigins []string
	Logf           func(string, ...any)
	Now            func() time.Time
}

// ListenLoopback listens on 127.0.0.1 with a random port.
func ListenLoopback() (net.Listener, error) { return net.Listen("tcp", "127.0.0.1:0") }

func loopbackHost(host string) bool {
	h, _, err := net.SplitHostPort(host)
	if err != nil {
		h = host
	}
	h = strings.Trim(h, "[]")
	return h == "127.0.0.1" || h == "localhost" || h == "::1"
}

func headerHasToken(h http.Header, name, token string) bool {
	for _, v := range h.Values(name) {
		for _, part := range strings.Split(v, ",") {
			if strings.EqualFold(strings.TrimSpace(part), token) {
				return true
			}
		}
	}
	return false
}

// ServeWebSocket serves pages on ln. Each connection must send
// {"t":"auth","token":...} within AuthTimeout with a token whose aud is this
// provider and whose origin equals the page's Origin header. The Host header
// must be a loopback name (DNS rebinding defense).
func (p *Provider) ServeWebSocket(ctx context.Context, ln net.Listener, opts WebSocketOptions) error {
	srv := &http.Server{Handler: p.webSocketHandler(opts), ReadHeaderTimeout: 5 * time.Second}
	go func() { <-ctx.Done(); srv.Close() }()
	err := srv.Serve(ln)
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

func (p *Provider) webSocketHandler(opts WebSocketOptions) http.Handler {
	return http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) {
		if !loopbackHost(r.Host) {
			http.Error(rw, "forbidden host", http.StatusForbidden)
			return
		}
		origin := r.Header.Get("Origin")
		if origin == "" {
			http.Error(rw, "origin required", http.StatusForbidden)
			return
		}
		if len(opts.AllowedOrigins) > 0 {
			ok := false
			for _, o := range opts.AllowedOrigins {
				ok = ok || o == origin
			}
			if !ok {
				http.Error(rw, "origin not allowed", http.StatusForbidden)
				return
			}
		}
		key := r.Header.Get("Sec-WebSocket-Key")
		raw, kerr := base64.StdEncoding.DecodeString(key)
		if r.Method != http.MethodGet || !headerHasToken(r.Header, "Connection", "upgrade") ||
			!headerHasToken(r.Header, "Upgrade", "websocket") ||
			r.Header.Get("Sec-WebSocket-Version") != "13" || kerr != nil || len(raw) != 16 {
			rw.Header().Set("Sec-WebSocket-Version", "13")
			http.Error(rw, "websocket upgrade required", http.StatusBadRequest)
			return
		}
		hj, ok := rw.(http.Hijacker)
		if !ok {
			http.Error(rw, "cannot hijack", http.StatusInternalServerError)
			return
		}
		nc, brw, err := hj.Hijack()
		if err != nil {
			return
		}
		if tc, ok := nc.(*net.TCPConn); ok {
			_ = tc.SetNoDelay(true) // Go's default, set explicitly per the latency rules
		}
		sum := sha1.Sum([]byte(key + wsGUID))
		accept := base64.StdEncoding.EncodeToString(sum[:])
		_, err = nc.Write([]byte("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n"))
		if err != nil {
			nc.Close()
			return
		}
		ws := &wsConn{nc: nc, br: brw.Reader}
		p.serveAuthenticated(ws, nc.SetReadDeadline, origin, DirectOptions{Logf: opts.Logf, Now: opts.Now})
	})
}
