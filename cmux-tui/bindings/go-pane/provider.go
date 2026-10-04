package pane

import (
	"context"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
)

// OpSpec is one op a provider serves. Generated Register functions build
// these; Handle validates params, calls the typed handler, and validates the
// result.
type OpSpec struct {
	Name   string
	Kind   string // "read" or "mutation"
	Scope  string
	Errors []string // op-specific error codes from the IR
	Handle func(ctx context.Context, call *Call, params json.RawMessage) (json.RawMessage, error)
}

// EventSpec is one event stream a provider serves.
type EventSpec struct {
	Name  string
	Scope string
	// Validate checks outgoing event data against the IR schema.
	Validate func(any) error
	// Match filters events per subscription. Nil means the stream accepts
	// no filter.
	Match func(filter, data json.RawMessage) bool
}

// Provider owns one or more namespaces and serves their ops and events on
// any number of connections (the router connection and direct data-plane
// connections).
type Provider struct {
	App        string
	Namespaces []string
	Interfaces []string
	IRVersion  string
	IRSHA256   string
	// OnRelease is called for {"t":"release"}; nil ignores releases.
	OnRelease func(c *Conn, handle string)
	// Logf defaults to log.Printf on each connection.
	Logf func(string, ...any)

	mu     sync.RWMutex
	ops    map[string]*OpSpec
	events map[string]*EventSpec
	subs   map[string]map[*serverSub]struct{}

	routerKey atomic.Pointer[ed25519.PublicKey]
}

var nsPattern = regexp.MustCompile(`^[a-z][a-z0-9_-]*(\.[a-z][a-z0-9_-]*)*$`)

// NewProvider creates a provider for app that owns namespaces. A third-party
// namespace is its app id in reverse DNS; the router enforces that, and this
// constructor only checks syntax.
func NewProvider(app string, namespaces ...string) (*Provider, error) {
	if !nsPattern.MatchString(app) {
		return nil, fmt.Errorf("pane: invalid app id %q", app)
	}
	if len(namespaces) == 0 {
		return nil, fmt.Errorf("pane: provider %q owns no namespaces", app)
	}
	for _, ns := range namespaces {
		if !nsPattern.MatchString(ns) {
			return nil, fmt.Errorf("pane: invalid namespace %q", ns)
		}
	}
	return &Provider{
		App: app, Namespaces: append([]string(nil), namespaces...),
		ops: map[string]*OpSpec{}, events: map[string]*EventSpec{},
		subs: map[string]map[*serverSub]struct{}{},
	}, nil
}

// Owns reports whether name (an op or event) is inside one of the provider's
// namespaces.
func (p *Provider) Owns(name string) bool {
	for _, ns := range p.Namespaces {
		if strings.HasPrefix(name, ns+".") {
			return true
		}
	}
	return false
}

// Register adds an op. The router refuses providers that declare ops outside
// their namespaces, so Register refuses them first.
func (p *Provider) Register(op OpSpec) error {
	if !p.Owns(op.Name) {
		return fmt.Errorf("pane: op %q is outside namespaces %v", op.Name, p.Namespaces)
	}
	if op.Handle == nil {
		return fmt.Errorf("pane: op %q has no handler", op.Name)
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if _, dup := p.ops[op.Name]; dup {
		return fmt.Errorf("pane: op %q registered twice", op.Name)
	}
	cp := op
	p.ops[op.Name] = &cp
	return nil
}

// RegisterEvent adds an event stream.
func (p *Provider) RegisterEvent(ev EventSpec) error {
	if !p.Owns(ev.Name) {
		return fmt.Errorf("pane: event %q is outside namespaces %v", ev.Name, p.Namespaces)
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if _, dup := p.events[ev.Name]; dup {
		return fmt.Errorf("pane: event %q registered twice", ev.Name)
	}
	cp := ev
	p.events[ev.Name] = &cp
	return nil
}

// RouterKey is the router's public key learned at admission (or set with
// SetRouterKey), or nil.
func (p *Provider) RouterKey() ed25519.PublicKey {
	if k := p.routerKey.Load(); k != nil {
		return *k
	}
	return nil
}

// SetRouterKey sets the key used to verify capability tokens.
func (p *Provider) SetRouterKey(k ed25519.PublicKey) {
	cp := append(ed25519.PublicKey(nil), k...)
	p.routerKey.Store(&cp)
}

func (p *Provider) serveCall(ctx context.Context, call *Call, auth Authorizer, params json.RawMessage, logf func(string, ...any)) (json.RawMessage, error) {
	p.mu.RLock()
	op := p.ops[call.Op]
	p.mu.RUnlock()
	if op == nil {
		return nil, Errorf(CodeUnknownOp, "no handler for %s", call.Op)
	}
	if err := auth.Authorize(op.Name, op.Scope); err != nil {
		return nil, err
	}
	value, err := op.Handle(ctx, call, params)
	if err == nil {
		return value, nil
	}
	var e *Error
	if !errors.As(err, &e) {
		if errors.Is(err, context.Canceled) {
			return nil, Errorf(CodeCancelled, "cancelled")
		}
		logf("pane: %s failed: %v", op.Name, err)
		return nil, Errorf(CodeInternal, "internal error")
	}
	if IsRuntimeCode(e.Code) {
		return nil, e
	}
	for _, code := range op.Errors {
		if code == e.Code {
			return nil, e
		}
	}
	// Peers rely on the IR's error list; an undeclared code is a provider
	// bug, so it is logged and reported as internal.
	logf("pane: %s returned undeclared error code %q: %s", op.Name, e.Code, e.Message)
	return nil, Errorf(CodeInternal, "internal error")
}

// serverSub is one subscription this side serves. Events go through a
// bounded queue drained by one goroutine, so a slow peer never blocks
// Publish; overflow drops the event and leaves a seq gap.
type serverSub struct {
	conn   *Conn
	id     uint64
	stream string
	filter json.RawMessage
	match  func(filter, data json.RawMessage) bool
	seq    atomic.Uint64
	queue  chan *Message
	quit   chan struct{}
	once   sync.Once
	prov   *Provider
}

const serverSubQueue = 256

func (s *serverSub) run() {
	for {
		select {
		case m := <-s.queue:
			if err := s.conn.send(m); err != nil {
				s.stop()
				return
			}
		case <-s.quit:
			return
		}
	}
}

func (s *serverSub) stop() {
	s.once.Do(func() {
		close(s.quit)
		s.prov.mu.Lock()
		delete(s.prov.subs[s.stream], s)
		s.prov.mu.Unlock()
	})
}

func (c *Conn) handleSub(m *Message) {
	id := *m.ID
	stream, _ := m.StreamName()
	if c.prov == nil {
		_ = c.send(NewErr(id, Errorf(CodeUnknownStream, "no provider on this connection")))
		return
	}
	p := c.prov
	p.mu.RLock()
	ev := p.events[stream]
	p.mu.RUnlock()
	if ev == nil {
		_ = c.send(NewErr(id, Errorf(CodeUnknownStream, "no event source for %s", stream)))
		return
	}
	if err := c.auth.Authorize(ev.Name, ev.Scope); err != nil {
		_ = c.send(NewErr(id, err))
		return
	}
	if len(m.Filter) > 0 && ev.Match == nil {
		_ = c.send(NewErr(id, Errorf(CodeInvalidParams, "stream %q takes no filter", stream)))
		return
	}
	s := &serverSub{conn: c, stream: stream, filter: m.Filter, match: ev.Match,
		queue: make(chan *Message, serverSubQueue), quit: make(chan struct{}), prov: p}
	c.mu.Lock()
	c.nextSub++
	s.id = c.nextSub
	c.served[s.id] = s
	c.mu.Unlock()
	value, _ := json.Marshal(map[string]uint64{"sub": s.id})
	// The ok is written before the subscription joins the fan-out, so no
	// event can precede it on the wire.
	if err := c.send(NewOK(id, value)); err != nil {
		return
	}
	p.mu.Lock()
	if p.subs[stream] == nil {
		p.subs[stream] = map[*serverSub]struct{}{}
	}
	p.subs[stream][s] = struct{}{}
	p.mu.Unlock()
	select {
	case <-s.quit: // the connection closed while we were adding it
		p.mu.Lock()
		delete(p.subs[stream], s)
		p.mu.Unlock()
		return
	default:
	}
	go s.run()
}

// Publish sends data to every subscriber of stream. data is validated
// against the event's IR schema first. It never blocks on a slow peer.
func (p *Provider) Publish(stream string, data json.RawMessage) error {
	p.mu.RLock()
	ev := p.events[stream]
	var targets []*serverSub
	for s := range p.subs[stream] {
		targets = append(targets, s)
	}
	p.mu.RUnlock()
	if ev == nil {
		return fmt.Errorf("pane: publish to unregistered stream %q", stream)
	}
	if ev.Validate != nil {
		v, err := DecodeValue(data)
		if err != nil {
			return err
		}
		if err := ev.Validate(v); err != nil {
			return fmt.Errorf("pane: %s event data: %w", stream, err)
		}
	}
	for _, s := range targets {
		if s.match != nil && len(s.filter) > 0 && !s.match(s.filter, data) {
			continue
		}
		seq := s.seq.Add(1)
		select {
		case s.queue <- NewEvent(s.id, seq, data):
		default:
		}
	}
	return nil
}
