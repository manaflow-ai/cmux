package pane

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"io"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"
)

// wsTestClient is a minimal RFC 6455 client that behaves like a browser page:
// it sends an Origin header and masks every frame.
type wsTestClient struct {
	t  *testing.T
	nc net.Conn
	br *bufio.Reader
}

func wsDial(t *testing.T, addr, host, origin string) (*wsTestClient, *http.Response) {
	t.Helper()
	nc, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { nc.Close() })
	keyBytes := make([]byte, 16)
	rand.Read(keyBytes)
	key := base64.StdEncoding.EncodeToString(keyBytes)
	req := "GET / HTTP/1.1\r\nHost: " + host + "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
		"Sec-WebSocket-Key: " + key + "\r\nSec-WebSocket-Version: 13\r\n"
	if origin != "" {
		req += "Origin: " + origin + "\r\n"
	}
	if _, err := nc.Write([]byte(req + "\r\n")); err != nil {
		t.Fatal(err)
	}
	br := bufio.NewReader(nc)
	resp, err := http.ReadResponse(br, nil)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode == http.StatusSwitchingProtocols {
		sum := sha1.Sum([]byte(key + wsGUID))
		if resp.Header.Get("Sec-WebSocket-Accept") != base64.StdEncoding.EncodeToString(sum[:]) {
			t.Fatal("bad Sec-WebSocket-Accept")
		}
	}
	return &wsTestClient{t: t, nc: nc, br: br}, resp
}

func (c *wsTestClient) frame(fin bool, opcode byte, payload []byte) {
	c.t.Helper()
	b0 := opcode
	if fin {
		b0 |= 0x80
	}
	hdr := []byte{b0}
	switch n := len(payload); {
	case n < 126:
		hdr = append(hdr, 0x80|byte(n))
	case n <= 0xFFFF:
		hdr = append(hdr, 0x80|126, byte(n>>8), byte(n))
	default:
		hdr = append(hdr, 0x80|127)
		hdr = binary.BigEndian.AppendUint64(hdr, uint64(n))
	}
	mask := []byte{1, 2, 3, 4}
	hdr = append(hdr, mask...)
	for i, b := range payload {
		hdr = append(hdr, b^mask[i%4])
	}
	if _, err := c.nc.Write(hdr); err != nil {
		c.t.Fatal(err)
	}
}

func (c *wsTestClient) sendText(s string) { c.frame(true, wsText, []byte(s)) }

func (c *wsTestClient) read() (byte, []byte, error) {
	_ = c.nc.SetReadDeadline(time.Now().Add(5 * time.Second))
	var h [2]byte
	if _, err := io.ReadFull(c.br, h[:]); err != nil {
		return 0, nil, err
	}
	if h[1]&0x80 != 0 {
		c.t.Fatal("server frames must not be masked")
	}
	n := uint64(h[1] & 0x7F)
	if n == 126 {
		var b [2]byte
		io.ReadFull(c.br, b[:])
		n = uint64(binary.BigEndian.Uint16(b[:]))
	} else if n == 127 {
		var b [8]byte
		io.ReadFull(c.br, b[:])
		n = binary.BigEndian.Uint64(b[:])
	}
	p := make([]byte, n)
	_, err := io.ReadFull(c.br, p)
	return h[0] & 0x0F, p, err
}

func (c *wsTestClient) readMessage() *Message {
	c.t.Helper()
	op, p, err := c.read()
	if err != nil || op != wsText {
		c.t.Fatalf("read: op %d err %v", op, err)
	}
	m, err := DecodeMessage(p)
	if err != nil {
		c.t.Fatal(err)
	}
	return m
}

const pageOrigin = "http://127.0.0.1:4230"

func startWS(t *testing.T, opts WebSocketOptions) (*testProvider, string, func(Claims) string) {
	t.Helper()
	tp := newTestProvider(t)
	pub, priv := testKey(t)
	tp.SetRouterKey(pub)
	ln, err := ListenLoopback()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	opts.Logf = quiet
	go tp.ServeWebSocket(ctx, ln, opts)
	mint := func(c Claims) string {
		tok, _ := MintToken(priv, c)
		return tok
	}
	return tp, ln.Addr().String(), mint
}

func pageClaims() Claims {
	c := testClaims()
	c.Origin = pageOrigin
	return c
}

func TestWebSocketPageCall(t *testing.T) {
	_, addr, mint := startWS(t, WebSocketOptions{AllowedOrigins: []string{pageOrigin}})
	c, resp := wsDial(t, addr, addr, pageOrigin)
	if resp.StatusCode != http.StatusSwitchingProtocols {
		t.Fatalf("status %d", resp.StatusCode)
	}
	c.sendText(`{"t":"auth","token":"` + mint(pageClaims()) + `"}`)
	if m := c.readMessage(); m.T != TypeOK || *m.ID != 0 {
		t.Fatalf("auth ack: %+v", m)
	}
	// A fragmented call, with a ping between the fragments.
	call := `{"t":"call","id":1,"op":"test.fast.op","params":{}}`
	c.frame(false, wsText, []byte(call[:10]))
	c.frame(true, wsPing, []byte("hi"))
	c.frame(true, wsContinuation, []byte(call[10:]))
	op, p, err := c.read()
	if err != nil || op != wsPong || string(p) != "hi" {
		t.Fatalf("pong: %d %q %v", op, p, err)
	}
	if m := c.readMessage(); m.T != TypeOK || *m.ID != 1 || string(m.Value) != `{"op":"fast"}` {
		t.Fatalf("call: %+v", m)
	}
	// Close handshake.
	c.frame(true, wsClose, []byte{0x03, 0xE8})
	if op, _, _ := c.read(); op != wsClose {
		t.Fatalf("close reply opcode %d", op)
	}
}

func TestWebSocketTokenOriginMustMatchPage(t *testing.T) {
	_, addr, mint := startWS(t, WebSocketOptions{})
	c, _ := wsDial(t, addr, addr, "http://127.0.0.1:9999") // another page's origin
	c.sendText(`{"t":"auth","token":"` + mint(pageClaims()) + `"}`)
	m := c.readMessage()
	if m.T != TypeErr || *m.ID != 0 || m.Code != CodeAuthRefused || !strings.Contains(*m.Message, "origin") {
		t.Fatalf("got %+v", m)
	}
}

func TestWebSocketRejectsBadHandshakes(t *testing.T) {
	_, addr, _ := startWS(t, WebSocketOptions{AllowedOrigins: []string{pageOrigin}})
	_, port, _ := net.SplitHostPort(addr)
	cases := map[string]struct{ host, origin string }{
		"rebound host":       {"evil.example:" + port, pageOrigin},
		"missing origin":     {addr, ""},
		"origin not allowed": {addr, "https://evil.example"},
	}
	for name, c := range cases {
		_, resp := wsDial(t, addr, c.host, c.origin)
		if resp.StatusCode != http.StatusForbidden {
			t.Errorf("%s: status %d", name, resp.StatusCode)
		}
	}
	// localhost is a loopback name and is accepted.
	if _, resp := wsDial(t, addr, "localhost:"+port, pageOrigin); resp.StatusCode != http.StatusSwitchingProtocols {
		t.Errorf("localhost: status %d", resp.StatusCode)
	}
}

func TestWebSocketBinaryFrameCloses(t *testing.T) {
	_, addr, mint := startWS(t, WebSocketOptions{})
	c, _ := wsDial(t, addr, addr, pageOrigin)
	c.sendText(`{"t":"auth","token":"` + mint(pageClaims()) + `"}`)
	c.readMessage()
	c.frame(true, wsBinary, []byte{0, 0, 0, 1, 0, 0, 0, 0})
	// Byte streams are not implemented, so a binary frame ends the session.
	for {
		op, _, err := c.read()
		if err != nil || op == wsClose {
			return
		}
	}
}
