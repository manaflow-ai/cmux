package pane

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"sort"
	"strconv"
)

// Environment variables a provider process reads.
const (
	// EnvRouterFD is set by the router when it spawns the provider: the
	// decimal number of an inherited socketpair fd connected to the router.
	// The runtime unsets it after use so grandchildren do not inherit it.
	EnvRouterFD = "CMUX_PANE_ROUTER_FD"
	// EnvRouterSocket is the router's unix socket path for a provider that
	// starts by itself.
	EnvRouterSocket = "CMUX_PANE_ROUTER_SOCKET"
	// EnvAppCredential is the app credential a self-started provider
	// presents at admission. Router-spawned providers do not need one: the
	// inherited fd is the credential.
	EnvAppCredential = "CMUX_PANE_APP_CREDENTIAL"
)

// ProtocolVersion is sent in the admission hello.
const ProtocolVersion = "cmux.pane/0"

// HelloOp is the admission call a provider sends first on its router
// connection.
const HelloOp = "cmux.router.hello"

// HelloParams is the admission request: who the provider is and exactly what
// it serves. The router checks the app's registration, refuses ops or events
// outside the app's namespaces, and answers with Welcome.
type HelloParams struct {
	Proto      string       `json:"proto"`
	App        string       `json:"app"`
	Namespaces []string     `json:"namespaces"`
	Ops        []HelloOpRef `json:"ops"`
	Events     []HelloEvent `json:"events"`
	Interfaces []string     `json:"interfaces"`
	IR         HelloIR      `json:"ir"`
	Endpoints  []Endpoint   `json:"endpoints"`
	Credential string       `json:"credential,omitempty"`
}

// HelloOpRef declares one served op.
type HelloOpRef struct {
	Name  string `json:"name"`
	Kind  string `json:"kind"`
	Scope string `json:"scope"`
}

// HelloEvent declares one served event stream.
type HelloEvent struct {
	Name  string `json:"name"`
	Scope string `json:"scope"`
}

// HelloIR names the IR the provider was generated from.
type HelloIR struct {
	Version string `json:"version"`
	SHA256  string `json:"sha256"`
}

// Endpoint is a direct data-plane address the provider listens on.
type Endpoint struct {
	Kind string `json:"kind"`           // "unix" or "ws"
	Path string `json:"path,omitempty"` // unix socket path
	URL  string `json:"url,omitempty"`  // ws://127.0.0.1:<port>/
}

// Welcome is the router's admission reply.
type Welcome struct {
	// RouterKey is unpadded base64url of the router's Ed25519 public key;
	// providers verify capability tokens with it.
	RouterKey string `json:"router_key"`
	// Provider is the router's id for this admitted provider instance.
	Provider string `json:"provider"`
}

// HelloOptions are the per-run parts of the hello.
type HelloOptions struct {
	Credential string
	Endpoints  []Endpoint
}

// Hello builds the admission request from the provider's registrations.
func (p *Provider) Hello(opts HelloOptions) HelloParams {
	p.mu.RLock()
	defer p.mu.RUnlock()
	h := HelloParams{
		Proto: ProtocolVersion, App: p.App,
		Namespaces: append([]string{}, p.Namespaces...),
		Ops:        []HelloOpRef{}, Events: []HelloEvent{},
		Interfaces: append([]string{}, p.Interfaces...),
		IR:         HelloIR{Version: p.IRVersion, SHA256: p.IRSHA256},
		Endpoints:  append([]Endpoint{}, opts.Endpoints...),
		Credential: opts.Credential,
	}
	for _, op := range p.ops {
		h.Ops = append(h.Ops, HelloOpRef{Name: op.Name, Kind: op.Kind, Scope: op.Scope})
	}
	for _, ev := range p.events {
		h.Events = append(h.Events, HelloEvent{Name: ev.Name, Scope: ev.Scope})
	}
	sort.Slice(h.Ops, func(i, j int) bool { return h.Ops[i].Name < h.Ops[j].Name })
	sort.Slice(h.Events, func(i, j int) bool { return h.Events[i].Name < h.Events[j].Name })
	return h
}

// Admit sends the hello on conn (which must be serving) and stores the
// router key from the welcome.
func (p *Provider) Admit(ctx context.Context, conn *Conn, opts HelloOptions) (*Welcome, error) {
	raw, err := conn.Call(ctx, HelloOp, p.Hello(opts))
	if err != nil {
		return nil, fmt.Errorf("pane: admission refused: %w", err)
	}
	var w Welcome
	if err := json.Unmarshal(raw, &w); err != nil {
		return nil, fmt.Errorf("pane: bad welcome: %w", err)
	}
	key, err := ParseRouterKey(w.RouterKey)
	if err != nil {
		return nil, err
	}
	p.SetRouterKey(key)
	return &w, nil
}

// ErrNoRouter means neither EnvRouterFD nor a socket path was given.
var ErrNoRouter = errors.New("pane: no router: set " + EnvRouterFD + " or " + EnvRouterSocket)

// DialRouter returns the router connection. An inherited fd (EnvRouterFD)
// wins; otherwise it dials socketPath, or EnvRouterSocket when socketPath is
// empty. The returned bool is true for an inherited fd.
func DialRouter(socketPath string) (net.Conn, bool, error) {
	if fdText, ok := os.LookupEnv(EnvRouterFD); ok {
		os.Unsetenv(EnvRouterFD)
		fd, err := strconv.Atoi(fdText)
		if err != nil || fd < 3 {
			return nil, false, fmt.Errorf("pane: %s=%q is not an inherited fd (>= 3)", EnvRouterFD, fdText)
		}
		f := os.NewFile(uintptr(fd), "cmux-pane-router")
		if f == nil {
			return nil, false, fmt.Errorf("pane: %s=%d is not open", EnvRouterFD, fd)
		}
		// FileConn dups the fd with close-on-exec; close the inherited one.
		c, err := net.FileConn(f)
		f.Close()
		if err != nil {
			return nil, false, fmt.Errorf("pane: %s=%d: %w", EnvRouterFD, fd, err)
		}
		return c, true, nil
	}
	if socketPath == "" {
		socketPath = os.Getenv(EnvRouterSocket)
	}
	if socketPath == "" {
		return nil, false, ErrNoRouter
	}
	c, err := net.Dial("unix", socketPath)
	if err != nil {
		return nil, false, fmt.Errorf("pane: dial router: %w", err)
	}
	return c, false, nil
}

// RunOptions configure Run.
type RunOptions struct {
	// RouterSocket is used when EnvRouterFD is unset; empty falls back to
	// EnvRouterSocket.
	RouterSocket string
	// Credential defaults to EnvAppCredential for a self-started provider.
	Credential string
	// Listen, when set, is a unix socket path for direct data-plane peers.
	// It is created with mode 0600 and announced in the hello.
	Listen string
	// WebSocket, when set, is a loopback address (usually "127.0.0.1:0")
	// where pages connect directly. It is announced in the hello as a ws
	// endpoint, which cmux.router.resolve hands to pages.
	WebSocket string
	// AllowedOrigins restricts WebSocket page origins (optional).
	AllowedOrigins []string
	Logf           func(string, ...any)
}

// Run connects to the router, gets admitted, serves the router connection
// and the optional direct listener, and returns when the router connection
// closes or ctx is done.
func (p *Provider) Run(ctx context.Context, opts RunOptions) error {
	rc, inherited, err := DialRouter(opts.RouterSocket)
	if err != nil {
		return err
	}
	cred := opts.Credential
	if cred == "" && !inherited {
		cred = os.Getenv(EnvAppCredential)
	}
	os.Unsetenv(EnvAppCredential)
	conn := NewConn(rc, ConnOptions{Provider: p, Auth: TrustPeer{}, Logf: opts.Logf})
	serveErr := make(chan error, 1)
	go func() { serveErr <- conn.Serve() }()
	defer conn.Close()

	var endpoints []Endpoint
	var ln net.Listener
	if opts.Listen != "" {
		ln, err = ListenUnix(opts.Listen)
		if err != nil {
			return err
		}
		defer ln.Close()
		endpoints = append(endpoints, Endpoint{Kind: "unix", Path: opts.Listen})
	}
	var wsln net.Listener
	if opts.WebSocket != "" {
		host, _, err := net.SplitHostPort(opts.WebSocket)
		if err != nil || !loopbackHost(host) {
			return fmt.Errorf("pane: WebSocket listener must bind loopback, got %q", opts.WebSocket)
		}
		wsln, err = net.Listen("tcp", opts.WebSocket)
		if err != nil {
			return err
		}
		defer wsln.Close()
		endpoints = append(endpoints, Endpoint{Kind: "ws", URL: "ws://" + wsln.Addr().String() + "/"})
	}
	if _, err := p.Admit(ctx, conn, HelloOptions{Credential: cred, Endpoints: endpoints}); err != nil {
		return err
	}
	if ln != nil {
		go p.ServeDirect(ctx, ln, DirectOptions{Logf: opts.Logf})
	}
	if wsln != nil {
		go p.ServeWebSocket(ctx, wsln, WebSocketOptions{AllowedOrigins: opts.AllowedOrigins, Logf: opts.Logf})
	}
	select {
	case err := <-serveErr:
		if errors.Is(err, io.EOF) || errors.Is(err, net.ErrClosed) {
			return nil
		}
		return err
	case <-ctx.Done():
		return ctx.Err()
	}
}
