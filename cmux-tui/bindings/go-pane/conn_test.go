package pane

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"os"
	"syscall"
	"testing"
	"time"
)

// socketpair returns two connected unix stream sockets, the same transport a
// router uses for the providers it spawns.
func socketpair(t *testing.T) (net.Conn, net.Conn) {
	t.Helper()
	fds, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	conns := make([]net.Conn, 2)
	for i, fd := range fds {
		f := os.NewFile(uintptr(fd), "socketpair")
		c, err := net.FileConn(f)
		f.Close()
		if err != nil {
			t.Fatal(err)
		}
		conns[i] = c
		t.Cleanup(func() { c.Close() })
	}
	return conns[0], conns[1]
}

func quiet(string, ...any) {}

type testProvider struct {
	*Provider
	slowRelease chan struct{}
	blockEnter  chan struct{}
	blockExit   chan error
}

func anyJSON(any) error { return nil }

// testOp is a catalog entry with permissive validators, standing in for the
// generated Catalog of a real IR.
func testOp(name string, mods ...func(*OpInfo)) OpInfo {
	op := OpInfo{Name: name, Kind: "read", Scope: "test:use", Risk: "read", ScopeClass: "standard",
		ValidateParams: anyJSON, ValidateResult: anyJSON}
	for _, m := range mods {
		m(&op)
	}
	return op
}

var testCatalog = &Catalog{
	IRVersion: "0.0.0-test",
	Ops: []OpInfo{
		testOp("test.fast.op"), testOp("test.slow.op"), testOp("test.block.op"),
		testOp("test.fail.declared", func(o *OpInfo) { o.Errors = []string{"test.nope"} }),
		testOp("test.fail.undeclared"), testOp("test.fail.plain"), testOp("test.fail.panic"),
		testOp("test.alias.target", func(o *OpInfo) { o.Aliases = []string{"short.name"} }),
		testOp("test.alias.other", func(o *OpInfo) { o.Aliases = []string{"short.name"} }),
		testOp("test.fs.stat", func(o *OpInfo) { o.Paths = []string{"path"} }),
		testOp("test.typed.op", func(o *OpInfo) {
			o.ValidateParams = func(v any) error {
				obj, err := AsObject(v, "")
				if err != nil {
					return err
				}
				return RequireFields(obj, "", "n")
			}
			o.ValidateResult = func(v any) error { return CheckString(v, "") }
		}),
		testOp("test.ask.user", func(o *OpInfo) { o.Kind = "mutation" }),
		testOp("test.stream.op", func(o *OpInfo) { o.Kind = "stream" }),
		testOp("test.unvalidated.op", func(o *OpInfo) { o.ValidateParams = nil }),
		testOp("page.ui.confirm", func(o *OpInfo) { o.Scope = "page:ui" }),
		testOp("other.x.y"),
		testOp(HelloOp, func(o *OpInfo) { o.Kind = "mutation"; o.Scope = "router:control" }),
	},
	Events: []EventInfo{{Name: "test.tick.fired", Scope: "test:use", Validate: anyJSON}},
}

func echo(tag string) Handler {
	return func(ctx context.Context, call *Call, raw json.RawMessage) (json.RawMessage, error) {
		return json.Marshal(map[string]string{"op": tag})
	}
}

func newTestProvider(t *testing.T) *testProvider {
	t.Helper()
	p, err := NewProvider("test", testCatalog, "test")
	if err != nil {
		t.Fatal(err)
	}
	tp := &testProvider{Provider: p, slowRelease: make(chan struct{}), blockEnter: make(chan struct{}, 1), blockExit: make(chan error, 1)}
	must := func(err error) {
		if err != nil {
			t.Fatal(err)
		}
	}
	must(p.Register("test.fast.op", echo("fast")))
	must(p.Register("test.slow.op", func(ctx context.Context, c *Call, raw json.RawMessage) (json.RawMessage, error) {
		<-tp.slowRelease
		return echo("slow")(ctx, c, raw)
	}))
	must(p.Register("test.block.op", func(ctx context.Context, c *Call, raw json.RawMessage) (json.RawMessage, error) {
		tp.blockEnter <- struct{}{}
		<-ctx.Done()
		tp.blockExit <- ctx.Err()
		return nil, ctx.Err()
	}))
	must(p.Register("test.fail.declared", func(context.Context, *Call, json.RawMessage) (json.RawMessage, error) {
		return nil, &Error{Code: "test.nope", Message: "declared", Retryable: true}
	}))
	must(p.Register("test.fail.undeclared", func(context.Context, *Call, json.RawMessage) (json.RawMessage, error) {
		return nil, &Error{Code: "test.secret", Message: "leaks internals"}
	}))
	must(p.Register("test.fail.plain", func(context.Context, *Call, json.RawMessage) (json.RawMessage, error) {
		return nil, errors.New("disk path /home/x leaked")
	}))
	must(p.Register("test.fail.panic", func(context.Context, *Call, json.RawMessage) (json.RawMessage, error) { panic("boom") }))
	must(p.RegisterEvent("test.tick.fired", EventHandler{}))
	if err := p.Register("other.x.y", echo("x")); err == nil {
		t.Fatal("op outside the namespace must be refused")
	}
	if err := p.Register("test.fast.op", echo("x")); err == nil {
		t.Fatal("duplicate op must be refused")
	}
	return tp
}

// pair serves tp on one end of a socketpair and returns a client Conn on the
// other end.
func pair(t *testing.T, tp *testProvider) *Conn {
	t.Helper()
	a, b := socketpair(t)
	server := NewConn(a, ConnOptions{Provider: tp.Provider, Logf: quiet})
	client := NewConn(b, ConnOptions{Logf: quiet})
	go server.Serve()
	go client.Serve()
	t.Cleanup(func() { client.Close(); server.Close() })
	return client
}

func wantCode(t *testing.T, err error, code string) *Error {
	t.Helper()
	var e *Error
	if !errors.As(err, &e) || e.Code != code {
		t.Fatalf("got %v, want %s", err, code)
	}
	return e
}

func TestCallOutOfOrderResults(t *testing.T) {
	tp := newTestProvider(t)
	c := pair(t, tp)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	slow := make(chan string, 1)
	go func() {
		v, err := c.Call(ctx, "test.slow.op", nil)
		if err != nil {
			slow <- err.Error()
			return
		}
		slow <- string(v)
	}()
	// The slow call (id 1) is in flight; the fast call (id 2) must finish first.
	v, err := c.Call(ctx, "test.fast.op", nil)
	if err != nil || string(v) != `{"op":"fast"}` {
		t.Fatalf("fast: %s %v", v, err)
	}
	select {
	case s := <-slow:
		t.Fatalf("slow finished before release: %s", s)
	default:
	}
	close(tp.slowRelease)
	if s := <-slow; s != `{"op":"slow"}` {
		t.Fatalf("slow: %s", s)
	}
}

// rawPeer drives the wire directly to see exactly what the provider sends.
type rawPeer struct {
	t  *testing.T
	nc net.Conn
}

func newRawPeer(t *testing.T, tp *testProvider) *rawPeer {
	a, b := socketpair(t)
	server := NewConn(a, ConnOptions{Provider: tp.Provider, Logf: quiet, MaxInflight: 2, Role: RoleAccepting})
	go server.Serve()
	t.Cleanup(func() { server.Close() })
	return &rawPeer{t: t, nc: b}
}

func (r *rawPeer) send(m *Message) {
	r.t.Helper()
	b, err := m.Encode()
	if err != nil {
		r.t.Fatal(err)
	}
	if err := WriteFrame(r.nc, b); err != nil {
		r.t.Fatal(err)
	}
}

func (r *rawPeer) sendRaw(s string) {
	r.t.Helper()
	if err := WriteFrame(r.nc, []byte(s)); err != nil {
		r.t.Fatal(err)
	}
}

func (r *rawPeer) recv() *Message {
	r.t.Helper()
	_ = r.nc.SetReadDeadline(time.Now().Add(5 * time.Second))
	b, err := ReadFrame(r.nc)
	if err != nil {
		r.t.Fatal(err)
	}
	m, err := DecodeMessage(b)
	if err != nil {
		r.t.Fatal(err)
	}
	return m
}

func TestCancelInFlightCall(t *testing.T) {
	tp := newTestProvider(t)
	r := newRawPeer(t, tp)
	r.send(NewCall(41, "test.block.op", nil))
	<-tp.blockEnter
	r.send(NewCancel(41))
	if err := <-tp.blockExit; !errors.Is(err, context.Canceled) {
		t.Fatalf("handler ctx: %v", err)
	}
	m := r.recv()
	if m.T != TypeErr || *m.ID != 41 || m.Code != CodeCancelled {
		t.Fatalf("got %+v", m)
	}
	// Cancel for an unknown id is ignored and the connection stays usable.
	r.send(NewCancel(999))
	r.send(NewCall(42, "test.fast.op", nil))
	if m := r.recv(); m.T != TypeOK || *m.ID != 42 {
		t.Fatalf("after cancel: %+v", m)
	}
}

func TestClientCancelSendsCancel(t *testing.T) {
	tp := newTestProvider(t)
	c := pair(t, tp)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { _, err := c.Call(ctx, "test.block.op", nil); done <- err }()
	<-tp.blockEnter
	cancel()
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatalf("client: %v", err)
	}
	if err := <-tp.blockExit; !errors.Is(err, context.Canceled) {
		t.Fatalf("provider handler was not cancelled: %v", err)
	}
}

func TestErrorMapping(t *testing.T) {
	tp := newTestProvider(t)
	c := pair(t, tp)
	ctx := context.Background()
	_, err := c.Call(ctx, "test.fail.declared", nil)
	if e := wantCode(t, err, "test.nope"); !e.Retryable || e.Message != "declared" {
		t.Fatalf("declared error lost fields: %+v", e)
	}
	for _, op := range []string{"test.fail.undeclared", "test.fail.plain", "test.fail.panic"} {
		_, err := c.Call(ctx, op, nil)
		if e := wantCode(t, err, CodeInternal); e.Message != "internal error" {
			t.Fatalf("%s leaked %q", op, e.Message)
		}
	}
	_, err = c.Call(ctx, "test.missing.op", nil)
	wantCode(t, err, CodeUnknownOp)
}

func TestBusyAndDuplicateID(t *testing.T) {
	tp := newTestProvider(t)
	r := newRawPeer(t, tp) // MaxInflight 2
	r.send(NewCall(1, "test.slow.op", nil))
	r.send(NewCall(1, "test.fast.op", nil))
	if m := r.recv(); m.T != TypeErr || *m.ID != 1 || m.Code != CodeBadMessage {
		t.Fatalf("duplicate id: %+v", m)
	}
	r.send(NewCall(2, "test.slow.op", nil))
	r.send(NewCall(3, "test.fast.op", nil))
	m := r.recv()
	if m.T != TypeErr || *m.ID != 3 || m.Code != CodeBusy || !*m.Retryable {
		t.Fatalf("busy: %+v", m)
	}
	close(tp.slowRelease)
	seen := map[uint64]bool{}
	for i := 0; i < 2; i++ {
		m := r.recv()
		if m.T != TypeOK {
			t.Fatalf("slow result: %+v", m)
		}
		seen[*m.ID] = true
	}
	if !seen[1] || !seen[2] {
		t.Fatalf("results %v", seen)
	}
}

func TestMalformedEnvelopeIsDropped(t *testing.T) {
	tp := newTestProvider(t)
	r := newRawPeer(t, tp)
	// A malformed message gets bad_message, echoing the id when it is
	// readable, and the connection stays open.
	r.sendRaw(`{"t":"call","id":1}`)
	if m := r.recv(); m.T != TypeErr || *m.ID != 1 || m.Code != CodeBadMessage {
		t.Fatalf("missing op: %+v", m)
	}
	r.sendRaw(`not json`)
	if m := r.recv(); m.T != TypeErr || *m.ID != 0 || m.Code != CodeBadMessage {
		t.Fatalf("not json: %+v", m)
	}
	r.send(NewCall(2, "test.fast.op", nil))
	if m := r.recv(); m.T != TypeOK || *m.ID != 2 {
		t.Fatalf("connection unusable after malformed messages: %+v", m)
	}
	// The raw peer dialed, so its stream ids must be odd. Byte streams are
	// not implemented, so a correct open is refused as unknown_op.
	r.sendRaw(`{"t":"open","id":3,"stream":1,"op":"test.blob.read"}`)
	if m := r.recv(); m.T != TypeErr || *m.ID != 3 || m.Code != CodeUnknownOp {
		t.Fatalf("open: %+v", m)
	}
	r.sendRaw(`{"t":"open","id":4,"stream":2,"op":"test.blob.read"}`)
	if m := r.recv(); m.T != TypeErr || *m.ID != 4 || m.Code != CodeStreamAborted {
		t.Fatalf("even open from the connecting side: %+v", m)
	}
	// A data frame for a stream that is not open is dropped.
	b, _ := EncodeBinaryFrame(BinaryFrame{Stream: 1, Payload: []byte("x")})
	if err := WriteBinaryFrame(r.nc, b); err != nil {
		t.Fatal(err)
	}
	r.send(NewCall(5, "test.fast.op", nil))
	if m := r.recv(); m.T != TypeOK || *m.ID != 5 {
		t.Fatalf("after data frame: %+v", m)
	}
	// A framing error is fatal.
	if _, err := r.nc.Write([]byte{0xFF, 0xFF, 0xFF, 0xFF}); err != nil {
		t.Fatal(err)
	}
	_ = r.nc.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := ReadFrame(r.nc); err == nil {
		t.Fatal("connection stayed open after an oversized frame prefix")
	}
}

func TestSubscribeEvents(t *testing.T) {
	tp := newTestProvider(t)
	c := pair(t, tp)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := c.Subscribe(ctx, "test.nope.stream", nil); err == nil {
		t.Fatal("unknown stream accepted")
	}
	if _, err := c.Subscribe(ctx, "test.tick.fired", json.RawMessage(`{"x":1}`)); err == nil {
		t.Fatal("filter accepted by a stream without Match")
	}
	sub, err := c.Subscribe(ctx, "test.tick.fired", nil)
	if err != nil {
		t.Fatal(err)
	}
	for i := 1; i <= 3; i++ {
		if err := tp.Publish("test.tick.fired", json.RawMessage(`{"n":`+string(rune('0'+i))+`}`)); err != nil {
			t.Fatal(err)
		}
	}
	for i := uint64(1); i <= 3; i++ {
		select {
		case ev := <-sub.Events():
			if ev.Seq != i || string(ev.Data) != `{"n":`+string(rune('0'+i))+`}` {
				t.Fatalf("event %d: %+v %s", i, ev, ev.Data)
			}
		case <-ctx.Done():
			t.Fatal("timed out waiting for events")
		}
	}
	if err := sub.Close(); err != nil {
		t.Fatal(err)
	}
	// After unsub the provider drops the subscriber.
	deadline := time.Now().Add(5 * time.Second)
	for {
		tp.mu.RLock()
		n := len(tp.subs["test.tick.fired"])
		tp.mu.RUnlock()
		if n == 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("subscriber not removed after unsub")
		}
		time.Sleep(10 * time.Millisecond)
	}
	if err := tp.Publish("test.unknown.stream", nil); err == nil {
		t.Fatal("publish to an unregistered stream must fail")
	}
}

func TestBothPeersMayCall(t *testing.T) {
	// The provider calls back into the page that called it.
	page, err := NewProvider("page", testCatalog, "page")
	if err != nil {
		t.Fatal(err)
	}
	_ = page.Register("page.ui.confirm", func(context.Context, *Call, json.RawMessage) (json.RawMessage, error) {
		return json.RawMessage(`true`), nil
	})
	prov, _ := NewProvider("test", testCatalog, "test")
	_ = prov.Register("test.ask.user", func(ctx context.Context, call *Call, raw json.RawMessage) (json.RawMessage, error) {
		return call.Conn.Call(ctx, "page.ui.confirm", nil)
	})
	a, b := socketpair(t)
	pc := NewConn(a, ConnOptions{Provider: page, Logf: quiet})
	sc := NewConn(b, ConnOptions{Provider: prov, Logf: quiet})
	go pc.Serve()
	go sc.Serve()
	defer pc.Close()
	defer sc.Close()
	v, err := pc.Call(context.Background(), "test.ask.user", nil)
	if err != nil || string(v) != "true" {
		t.Fatalf("callback: %s %v", v, err)
	}
}

func TestPendingCallsFailOnClose(t *testing.T) {
	tp := newTestProvider(t)
	a, b := socketpair(t)
	server := NewConn(a, ConnOptions{Provider: tp.Provider, Logf: quiet})
	client := NewConn(b, ConnOptions{Logf: quiet})
	go server.Serve()
	go client.Serve()
	done := make(chan error, 1)
	go func() { _, err := client.Call(context.Background(), "test.block.op", nil); done <- err }()
	<-tp.blockEnter
	server.Close()
	wantCode(t, <-done, CodeClosed)
	if err := <-tp.blockExit; !errors.Is(err, context.Canceled) {
		t.Fatalf("handler not cancelled on close: %v", err)
	}
	<-client.Done()
}
