package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	pane "github.com/manaflow-ai/cmux/cmux-tui/bindings/go-pane"
	"github.com/manaflow-ai/cmux/cmux-tui/bindings/go-pane/examples/hello/hellopane"
)

// The test binary doubles as the provider process: with HELLO_HELPER=1 it
// runs main's logic, so the tests exercise a real child process that inherits
// an fd or dials a socket, exactly as the router would start it.
func TestMain(m *testing.M) {
	if os.Getenv("HELLO_HELPER") == "1" {
		var args []string
		if a := os.Getenv("HELLO_ARGS"); a != "" {
			args = strings.Fields(a)
		}
		if err := run(context.Background(), args); err != nil {
			os.Stderr.WriteString("hello helper: " + err.Error() + "\n")
			os.Exit(1)
		}
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func quiet(string, ...any) {}

// fakeRouter admits one provider and then calls it.
type fakeRouter struct {
	pub   ed25519.PublicKey
	priv  ed25519.PrivateKey
	hello chan pane.HelloParams
}

func newFakeRouter(t *testing.T) *fakeRouter {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return &fakeRouter{pub: pub, priv: priv, hello: make(chan pane.HelloParams, 1)}
}

// serve runs the router side on nc and returns the connection once the
// provider is admitted.
func (r *fakeRouter) serve(t *testing.T, nc net.Conn) *pane.Conn {
	t.Helper()
	// The fake router serves cmux.router.hello from the real IR catalog, so
	// the runtime validates the provider's hand-written hello against
	// ProviderHello and the welcome against ProviderWelcome.
	rp, err := pane.NewProvider("cmux", hellopane.Catalog, "cmux")
	if err != nil {
		t.Fatal(err)
	}
	err = rp.Register(pane.HelloOp,
		func(ctx context.Context, call *pane.Call, raw json.RawMessage) (json.RawMessage, error) {
			var h pane.HelloParams
			if err := json.Unmarshal(raw, &h); err != nil {
				return nil, pane.Errorf(pane.CodeInvalidParams, "%v", err)
			}
			// Admission policy: every declared op and event must be inside
			// a namespace the app owns.
			for _, op := range h.Ops {
				if !strings.HasPrefix(op.Name, h.App+".") {
					return nil, pane.Errorf("cmux.router.outside_namespace", "%s", op.Name)
				}
			}
			if e := pane.CheckHello(&h, hellopane.IRSHA256); e != nil {
				return nil, e
			}
			r.hello <- h
			return json.Marshal(pane.Welcome{RouterKey: pane.EncodeRouterKey(r.pub), Provider: h.App})
		})
	if err != nil {
		t.Fatal(err)
	}
	conn := pane.NewConn(nc, pane.ConnOptions{Provider: rp, Logf: quiet})
	go conn.Serve()
	t.Cleanup(func() { conn.Close() })
	return conn
}

func (r *fakeRouter) waitHello(t *testing.T) pane.HelloParams {
	t.Helper()
	select {
	case h := <-r.hello:
		return h
	case <-time.After(10 * time.Second):
		t.Fatal("provider never sent hello")
		return pane.HelloParams{}
	}
}

func checkHello(t *testing.T, h pane.HelloParams, wantCred string) {
	t.Helper()
	if h.App != "com.example.hello" || h.Proto != pane.ProtocolVersion ||
		len(h.Namespaces) != 1 || h.Namespaces[0] != "com.example.hello" ||
		len(h.Ops) != 1 || h.Ops[0] != (pane.HelloOpRef{Name: "com.example.hello.greet.say", Kind: "read", Scope: "hello:read"}) ||
		h.IR.SHA256 != hellopane.IRSHA256 || h.Credential != wantCred {
		t.Fatalf("hello %+v", h)
	}
}

func exerciseProvider(t *testing.T, conn *pane.Conn) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	client := hellopane.NewClient(conn).ComExampleHello()
	res, err := client.GreetSay(ctx, hellopane.HelloParams{Name: "Leo"})
	if err != nil || res.Message != "hello, Leo" {
		t.Fatalf("greet: %+v %v", res, err)
	}
	// The provider validates params from the IR even when the caller skips
	// the typed client.
	bad := map[string]string{
		`{"name":5}`:             "/name: expected string",
		`{}`:                     `missing required property "name"`,
		`{"name":"a","admin":1}`: `unexpected property "admin"`,
	}
	for params, want := range bad {
		_, err := conn.Call(ctx, hellopane.OpComExampleHelloGreetSay, json.RawMessage(params))
		var e *pane.Error
		if !errors.As(err, &e) || e.Code != pane.CodeInvalidParams || !strings.Contains(e.Message, want) {
			t.Errorf("%s: got %v, want invalid_params %q", params, err, want)
		}
	}
	_, err = client.GreetSay(ctx, hellopane.HelloParams{Name: "  "})
	var e *pane.Error
	if !errors.As(err, &e) || e.Code != pane.CodeInvalidParams {
		t.Fatalf("empty name: %v", err)
	}
	_, err = conn.Call(ctx, "com.example.hello.greet.shout", nil)
	if !errors.As(err, &e) || e.Code != pane.CodeUnknownOp {
		t.Fatalf("unknown op: %v", err)
	}
}

func helperCmd(t *testing.T, args string, env ...string) *exec.Cmd {
	cmd := exec.Command(os.Args[0], "-test.run=^/")
	cmd.Env = append(os.Environ(), "HELLO_HELPER=1", "HELLO_ARGS="+args)
	cmd.Env = append(cmd.Env, env...)
	cmd.Stderr = os.Stderr
	return cmd
}

func socketpair(t *testing.T) (*os.File, *os.File) {
	fds, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	// Both ends are close-on-exec; ExtraFiles re-opens only the provider end
	// in the child. A router must do the same, or the child also holds the
	// router's end and never sees EOF when the router goes away.
	syscall.CloseOnExec(fds[0])
	syscall.CloseOnExec(fds[1])
	return os.NewFile(uintptr(fds[0]), "router-end"), os.NewFile(uintptr(fds[1]), "provider-end")
}

func shortTempDir(t *testing.T) string {
	dir, err := os.MkdirTemp("/tmp", "hello-")
	if err != nil {
		t.Fatal(err)
	}
	os.Chmod(dir, 0o700)
	t.Cleanup(func() { os.RemoveAll(dir) })
	return dir
}

func stopChild(t *testing.T, conn *pane.Conn, cmd *exec.Cmd) {
	t.Helper()
	conn.Close() // the provider exits when its router connection closes
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("provider exited with %v", err)
		}
	case <-time.After(10 * time.Second):
		cmd.Process.Kill()
		t.Fatal("provider did not exit after the router closed")
	}
}

// Router-spawned: the provider inherits one end of a socketpair as fd 3.
func TestRouterSpawnedInheritedFD(t *testing.T) {
	router := newFakeRouter(t)
	routerEnd, providerEnd := socketpair(t)
	cmd := helperCmd(t, "", pane.EnvRouterFD+"=3", pane.EnvAppCredential+"=must-not-be-sent")
	cmd.ExtraFiles = []*os.File{providerEnd} // becomes fd 3 in the child
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	providerEnd.Close()
	nc, err := net.FileConn(routerEnd)
	routerEnd.Close()
	if err != nil {
		t.Fatal(err)
	}
	conn := router.serve(t, nc)
	checkHello(t, router.waitHello(t), "")
	exerciseProvider(t, conn)
	stopChild(t, conn, cmd)
}

// Self-started: the provider dials the router's socket and presents an app
// credential. It also serves a direct data-plane socket for token holders.
func TestSelfStartedUnixSocket(t *testing.T) {
	router := newFakeRouter(t)
	dir := shortTempDir(t)
	routerPath := filepath.Join(dir, "router.sock")
	directPath := filepath.Join(dir, "hello.sock")
	ln, err := pane.ListenUnix(routerPath)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	cmd := helperCmd(t, "-router "+routerPath+" -listen "+directPath+" -ws 127.0.0.1:0", pane.EnvAppCredential+"=app-secret")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	nc, err := ln.Accept()
	if err != nil {
		t.Fatal(err)
	}
	conn := router.serve(t, nc)
	h := router.waitHello(t)
	checkHello(t, h, "app-secret")
	if len(h.Endpoints) != 2 || h.Endpoints[0] != (pane.Endpoint{Kind: "unix", Path: directPath}) ||
		h.Endpoints[1].Kind != "ws" || !strings.HasPrefix(h.Endpoints[1].URL, "ws://127.0.0.1:") {
		t.Fatalf("endpoints %+v", h.Endpoints)
	}
	// The announced page endpoint is live: a request that is not a WebSocket
	// upgrade is refused with 400 (the pane package tests drive full pages).
	req, _ := http.NewRequest("GET", "http"+strings.TrimPrefix(h.Endpoints[1].URL, "ws"), nil)
	req.Header.Set("Origin", "http://127.0.0.1:4230")
	if resp, err := http.DefaultClient.Do(req); err != nil || resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("ws endpoint: %v %v", resp, err)
	}
	exerciseProvider(t, conn)

	// Data plane: a page-side peer connects directly with a router-minted
	// token; the router is not on this path.
	tok, err := pane.MintToken(router.priv, pane.Claims{
		Sub: "surface:7", App: "com.acme.page", NS: []string{"com.example.hello"},
		Scopes: []string{"hello:read"}, Exp: time.Now().Add(time.Minute).Unix(), Aud: "com.example.hello",
	})
	if err != nil {
		t.Fatal(err)
	}
	dc, err := net.Dial("unix", directPath)
	if err != nil {
		t.Fatal(err)
	}
	authMsg, _ := pane.NewAuth(tok).Encode()
	if err := pane.WriteFrame(dc, authMsg); err != nil {
		t.Fatal(err)
	}
	direct := pane.NewConn(dc, pane.ConnOptions{Logf: quiet})
	go direct.Serve()
	defer direct.Close()
	res, err := hellopane.NewClient(direct).ComExampleHello().GreetSay(context.Background(), hellopane.HelloParams{Name: "page"})
	if err != nil || res.Message != "hello, page" {
		t.Fatalf("direct greet: %+v %v", res, err)
	}
	stopChild(t, conn, cmd)
}

func TestNoRouterConfigured(t *testing.T) {
	cmd := helperCmd(t, "")
	cmd.Env = append(cmd.Env, pane.EnvRouterFD+"=", pane.EnvRouterSocket+"=")
	var filtered []string
	for _, kv := range cmd.Env {
		if !strings.HasPrefix(kv, pane.EnvRouterFD+"=") && !strings.HasPrefix(kv, pane.EnvRouterSocket+"=") {
			filtered = append(filtered, kv)
		}
	}
	cmd.Env = filtered
	cmd.Stderr = nil
	if out, err := cmd.CombinedOutput(); err == nil || !strings.Contains(string(out), "no router") {
		t.Fatalf("got %v: %s", err, out)
	}
}
