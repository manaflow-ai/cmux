package pane

import (
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func shortTempDir(t *testing.T) string {
	t.Helper()
	// macOS limits unix socket paths to 104 bytes; t.TempDir() is too long.
	dir, err := os.MkdirTemp("/tmp", "pane-")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return dir
}

func startDirect(t *testing.T) (*testProvider, string, func(Claims) string) {
	t.Helper()
	tp := newTestProvider(t)
	pub, priv := testKey(t)
	tp.SetRouterKey(pub)
	path := filepath.Join(shortTempDir(t), "p.sock")
	ln, err := ListenUnix(path)
	if err != nil {
		t.Fatal(err)
	}
	if st, _ := os.Stat(path); st.Mode().Perm() != 0o600 {
		t.Fatalf("socket mode %v", st.Mode().Perm())
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go tp.ServeDirect(ctx, ln, DirectOptions{Logf: quiet})
	mint := func(c Claims) string {
		tok, err := MintToken(priv, c)
		if err != nil {
			t.Fatal(err)
		}
		return tok
	}
	return tp, path, mint
}

func testClaims() Claims {
	return Claims{Sub: "surface:1", App: "com.acme.page", NS: []string{"test"}, Scopes: []string{"test:use"},
		Exp: time.Now().Add(time.Minute).Unix(), Aud: "test"}
}

func dialDirect(t *testing.T, path string, first *Message) (*Conn, net.Conn) {
	t.Helper()
	nc := dialRaw(t, path)
	b, _ := first.Encode()
	if err := WriteFrame(nc, b); err != nil {
		t.Fatal(err)
	}
	c := NewConn(nc, ConnOptions{Logf: quiet})
	go c.Serve()
	t.Cleanup(func() { c.Close() })
	return c, nc
}

func dialRaw(t *testing.T, path string) net.Conn {
	t.Helper()
	nc, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { nc.Close() })
	return nc
}

func TestDirectAuthAndCall(t *testing.T) {
	_, path, mint := startDirect(t)
	c, _ := dialDirect(t, path, NewAuth(mint(testClaims())))
	v, err := c.Call(context.Background(), "test.fast.op", nil)
	if err != nil || string(v) != `{"op":"fast"}` {
		t.Fatalf("%s %v", v, err)
	}
}

func TestDirectRejectsWrongAudience(t *testing.T) {
	_, path, mint := startDirect(t)
	claims := testClaims()
	claims.Aud = "com.acme.other"
	nc := dialRaw(t, path)
	b, _ := NewAuth(mint(claims)).Encode()
	_ = WriteFrame(nc, b)
	_ = nc.SetReadDeadline(time.Now().Add(5 * time.Second))
	reply, err := ReadFrame(nc)
	if err != nil {
		t.Fatal(err)
	}
	m, _ := DecodeMessage(reply)
	if m.T != TypeErr || *m.ID != 0 || m.Code != CodeAuthRefused {
		t.Fatalf("got %+v", m)
	}
	if _, err := ReadFrame(nc); err == nil {
		t.Fatal("connection not closed after failed auth")
	}
}

func TestDirectRequiresAuthFirst(t *testing.T) {
	_, path, _ := startDirect(t)
	nc := dialRaw(t, path)
	b, _ := NewCall(1, "test.fast.op", nil).Encode()
	_ = WriteFrame(nc, b)
	_ = nc.SetReadDeadline(time.Now().Add(5 * time.Second))
	reply, err := ReadFrame(nc)
	if err != nil {
		t.Fatal(err)
	}
	if m, _ := DecodeMessage(reply); m.Code != CodeAuthRefused {
		t.Fatalf("got %+v", m)
	}
}

func TestDirectAuthTimeout(t *testing.T) {
	_, path, _ := startDirect(t)
	nc, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer nc.Close()
	start := time.Now()
	_ = nc.SetReadDeadline(time.Now().Add(AuthTimeout + 3*time.Second))
	b, err := ReadFrame(nc)
	if err != nil {
		t.Fatal(err)
	}
	m, _ := DecodeMessage(b)
	if m.T != TypeErr || *m.ID != 0 || m.Code != CodeAuthRefused || string(m.Details) != `{"reason":"timeout"}` {
		t.Fatalf("timeout refusal: %+v", m)
	}
	if elapsed := time.Since(start); elapsed < AuthTimeout-100*time.Millisecond || elapsed > AuthTimeout+2*time.Second {
		t.Fatalf("refused after %v, want about %v", elapsed, AuthTimeout)
	}
	if _, err := ReadFrame(nc); err == nil {
		t.Fatal("connection stayed open after the refusal")
	}
}

func TestDirectScopeAndRefresh(t *testing.T) {
	tp, path, mint := startDirect(t)
	claims := testClaims()
	claims.Scopes = nil
	claims.Ops = []string{"test.fast.op"}
	c, _ := dialDirect(t, path, NewAuth(mint(claims)))
	ctx := context.Background()
	if _, err := c.Call(ctx, "test.fast.op", nil); err != nil {
		t.Fatal(err)
	}
	_, err := c.Call(ctx, "test.fail.declared", nil)
	wantCode(t, err, CodeForbidden)
	_, err = c.Subscribe(ctx, "test.tick.fired", nil)
	wantCode(t, err, CodeForbidden)

	// Refresh: a later auth replaces the token's grants.
	if err := c.Send(NewAuth(mint(testClaims()))); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		_, err = c.Call(ctx, "test.fail.declared", nil)
		if e, ok := err.(*Error); ok && e.Code == "test.nope" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("refresh not applied: %v", err)
		}
		time.Sleep(10 * time.Millisecond)
	}
	_ = tp
}

func TestDirectTokenExpiresMidConnection(t *testing.T) {
	tp := newTestProvider(t)
	pub, priv := testKey(t)
	tp.SetRouterKey(pub)
	now := time.Now()
	clock := &now
	auth := &tokenAuth{prov: tp.Provider, now: func() time.Time { return *clock }}
	claims := testClaims()
	claims.Exp = now.Add(time.Minute).Unix()
	tok, _ := MintToken(priv, claims)
	if e := auth.reauth(tok); e != nil {
		t.Fatal(e)
	}
	if e := auth.Authorize("test.fast.op", "test:use"); e != nil {
		t.Fatal(e)
	}
	later := now.Add(2 * time.Minute)
	clock = &later
	e := auth.Authorize("test.fast.op", "test:use")
	if e == nil || e.Code != CodeTokenExpired || !e.Retryable {
		t.Fatalf("expired token: %+v", e)
	}
}

func TestAdmission(t *testing.T) {
	tp := newTestProvider(t)
	tp.IRVersion, tp.IRSHA256 = "0.1.0", "abc"
	pub, _ := testKey(t)
	a, b := socketpair(t)
	router, _ := NewProvider("cmux", testCatalog, "cmux")
	got := make(chan HelloParams, 1)
	_ = router.Register(HelloOp, func(ctx context.Context, call *Call, raw json.RawMessage) (json.RawMessage, error) {
		var h HelloParams
		if err := json.Unmarshal(raw, &h); err != nil {
			return nil, err
		}
		got <- h
		return json.Marshal(Welcome{RouterKey: EncodeRouterKey(pub), Provider: "prov-1"})
	})
	rc := NewConn(a, ConnOptions{Provider: router, Logf: quiet})
	pc := NewConn(b, ConnOptions{Provider: tp.Provider, Logf: quiet})
	go rc.Serve()
	go pc.Serve()
	defer rc.Close()
	defer pc.Close()
	w, err := tp.Admit(context.Background(), pc, HelloOptions{Credential: "cred"})
	if err != nil {
		t.Fatal(err)
	}
	h := <-got
	if w.Provider != "prov-1" || !tp.RouterKey().Equal(pub) {
		t.Fatalf("welcome %+v", w)
	}
	if h.Proto != ProtocolVersion || h.App != "test" || h.Credential != "cred" || h.IR.SHA256 != "abc" ||
		len(h.Ops) != 7 || h.Ops[0].Name != "test.block.op" || len(h.Events) != 1 {
		t.Fatalf("hello %+v", h)
	}
}
