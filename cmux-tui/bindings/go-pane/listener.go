package pane

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// AuthTimeout is how long a direct peer has to send {"t":"auth"}.
const AuthTimeout = 2 * time.Second

// ListenUnix listens on path with mode 0600. The parent directory must be
// owned by the current user and not group- or world-writable; a stale socket
// at path is replaced.
func ListenUnix(path string) (net.Listener, error) {
	dir := filepath.Dir(path)
	st, err := os.Stat(dir)
	if err != nil {
		return nil, fmt.Errorf("pane: listen dir: %w", err)
	}
	if st.Mode().Perm()&0o022 != 0 {
		return nil, fmt.Errorf("pane: listen dir %s is group- or world-writable", dir)
	}
	if fi, err := os.Lstat(path); err == nil {
		if fi.Mode()&os.ModeSocket == 0 {
			return nil, fmt.Errorf("pane: %s exists and is not a socket", path)
		}
		_ = os.Remove(path)
	}
	ln, err := net.Listen("unix", path)
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(path, 0o600); err != nil {
		ln.Close()
		return nil, err
	}
	return ln, nil
}

// DirectOptions configure ServeDirect.
type DirectOptions struct {
	Logf func(string, ...any)
	Now  func() time.Time
}

// ServeDirect accepts data-plane peers on ln. Each peer must first send
// {"t":"auth","token":...} with a capability token for this provider within
// AuthTimeout; every call is then checked against the token. A later auth
// message replaces the token (refresh).
func (p *Provider) ServeDirect(ctx context.Context, ln net.Listener, opts DirectOptions) error {
	go func() { <-ctx.Done(); ln.Close() }()
	for {
		nc, err := ln.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return nil
			}
			return err
		}
		go p.serveDirectConn(nc, opts)
	}
}

func (p *Provider) serveDirectConn(nc net.Conn, opts DirectOptions) {
	p.serveAuthenticated(FramedTransport(nc), nc.SetReadDeadline, "", opts)
}

// Auth refusal reasons sent in details.reason (Rust lane R5).
const (
	AuthReasonTimeout      = "timeout"
	AuthReasonClosed       = "closed"
	AuthReasonMissingToken = "missing_token"
	AuthReasonInvalidToken = "invalid_token"
)

func authRefused(reason, format string, args ...any) *Error {
	e := Errorf(CodeAuthRefused, format, args...)
	e.Details, _ = json.Marshal(map[string]string{"reason": reason})
	return e
}

// serveAuthenticated requires {"t":"auth"} as the first message within
// AuthTimeout, verifies the token for this provider (and origin, when the
// transport has one), acknowledges with ok id 0, then serves the connection
// with per-call checks. A refusal is err id 0 with code auth_refused and
// details.reason, then close (WebSocket close code 4001).
func (p *Provider) serveAuthenticated(tr Transport, setReadDeadline func(time.Time) error, origin string, opts DirectOptions) {
	auth := &tokenAuth{prov: p, now: opts.Now, origin: origin}
	reject := func(e *Error) {
		if raw, err := NewErr(0, e).Encode(); err == nil {
			_ = tr.WriteMessage(raw)
		}
		if rc, ok := tr.(refusingCloser); ok {
			rc.CloseAuthRefused()
		} else {
			tr.Close()
		}
	}
	_ = setReadDeadline(time.Now().Add(AuthTimeout))
	f, err := tr.ReadMessage()
	if err != nil {
		var ne net.Error
		if errors.As(err, &ne) && ne.Timeout() {
			_ = setReadDeadline(time.Time{})
			reject(authRefused(AuthReasonTimeout, "no auth within %v", AuthTimeout))
			return
		}
		tr.Close()
		return
	}
	_ = setReadDeadline(time.Time{})
	if f.Binary {
		reject(authRefused(AuthReasonMissingToken, "first message must be auth"))
		return
	}
	m, err := DecodeMessage(f.Payload)
	if err != nil || m.T != TypeAuth {
		reject(authRefused(AuthReasonMissingToken, "first message must be auth"))
		return
	}
	if e := auth.reauth(*m.Token); e != nil {
		reject(e)
		return
	}
	// Auth ack: ok id 0 with who the token names.
	c := auth.Claims()
	ack := map[string]any{"sub": c.Sub, "exp": c.Exp, "provider": p.App}
	if c.Page != "" {
		ack["page"] = c.Page
	} else {
		ack["app"] = c.App
	}
	value, _ := json.Marshal(ack)
	if raw, err := NewOK(0, value).Encode(); err != nil || tr.WriteMessage(raw) != nil {
		tr.Close()
		return
	}
	conn := NewTransportConn(tr, ConnOptions{Provider: p, Auth: auth, Logf: opts.Logf, Role: RoleAccepting})
	_ = conn.Serve()
}

// tokenAuth authorizes a direct peer by its capability token.
type tokenAuth struct {
	prov   *Provider
	now    func() time.Time
	origin string // the peer's Origin header for WebSocket peers; "" for unix
	mu     sync.Mutex
	claims *Claims
}

func (a *tokenAuth) clock() time.Time {
	if a.now != nil {
		return a.now()
	}
	return time.Now()
}

func (a *tokenAuth) reauth(token string) *Error {
	key := a.prov.RouterKey()
	if key == nil {
		return authRefused(AuthReasonInvalidToken, "provider has no router key yet")
	}
	c, err := VerifyToken(token, key, VerifyOptions{Audience: a.prov.App, Origin: a.origin, Now: a.clock})
	if err != nil {
		return authRefused(AuthReasonInvalidToken, "%v", err)
	}
	a.mu.Lock()
	a.claims = c
	a.mu.Unlock()
	return nil
}

func (a *tokenAuth) Claims() *Claims {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.claims
}

func (a *tokenAuth) Authorize(op, scope string) *Error {
	c := a.Claims()
	if c == nil {
		return Errorf(CodeAuthRefused, "no capability token")
	}
	if a.clock().Unix() >= c.Exp {
		return &Error{Code: CodeTokenExpired, Message: "capability token expired; refresh it with auth", Retryable: true}
	}
	if !c.Grants(op, scope) {
		return Errorf(CodeForbidden, "token does not grant %s (scope %s)", op, scope)
	}
	return nil
}
