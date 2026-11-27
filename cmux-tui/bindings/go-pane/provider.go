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

// Catalog is the IR a provider enforces: per op the scope, path params,
// risk metadata and the generated params and result validators. Generated
// packages export it (Catalog). The runtime takes every security-relevant
// fact from here, never from the code that registers a handler, so a
// hand-written handler cannot skip validation or confinement.
type Catalog struct {
	IRVersion string
	IRSHA256  string
	Ops       []OpInfo
	Events    []EventInfo
}

// EventInfo is one event stream of the IR.
type EventInfo struct {
	Name     string
	Scope    string
	Validate func(any) error // event data validator
}

// Handler serves one op. params are already authorized, confined and
// validated against the IR; the returned value is validated before it is
// sent.
type Handler func(ctx context.Context, call *Call, params json.RawMessage) (json.RawMessage, error)

// EventHandler serves one event stream.
type EventHandler struct {
	// Match filters events per subscription. Nil means the stream accepts
	// no filter.
	Match func(filter, data json.RawMessage) bool
	// OnSubscribe, when set, runs for each new subscription before the ok
	// is sent. Returning an error refuses the subscription. It must not
	// block: start a goroutine for ongoing emission and stop it when ctx is
	// done (unsub or connection close). Events emitted through the sink go
	// only to that subscription and always follow the ok on the wire.
	OnSubscribe func(ctx context.Context, call *Call, sink *Sink) error
}

type registeredOp struct {
	info   *OpInfo
	handle Handler
}

type registeredEvent struct {
	info *EventInfo
	EventHandler
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

	catalogOps    map[string]*OpInfo
	catalogEvents map[string]*EventInfo

	mu     sync.RWMutex
	ops    map[string]*registeredOp // by op name and alias
	events map[string]*registeredEvent
	subs   map[string]map[*serverSub]struct{}

	routerKey atomic.Pointer[ed25519.PublicKey]
}

// Namespace and app id labels are [a-z0-9_], dot-separated, the first label
// starting with a letter (Rust lane R11).
var nsPattern = regexp.MustCompile(`^[a-z][a-z0-9_]*(\.[a-z0-9_]+)*$`)

// NewProvider creates a provider for app that owns namespaces and enforces
// catalog. A third-party namespace is its app id; the router enforces that,
// and this constructor only checks syntax.
func NewProvider(app string, catalog *Catalog, namespaces ...string) (*Provider, error) {
	if !nsPattern.MatchString(app) {
		return nil, fmt.Errorf("pane: invalid app id %q", app)
	}
	if catalog == nil {
		return nil, errors.New("pane: a provider needs the IR catalog")
	}
	if len(namespaces) == 0 {
		return nil, fmt.Errorf("pane: provider %q owns no namespaces", app)
	}
	for _, ns := range namespaces {
		if !nsPattern.MatchString(ns) {
			return nil, fmt.Errorf("pane: invalid namespace %q", ns)
		}
	}
	p := &Provider{
		App: app, Namespaces: append([]string(nil), namespaces...),
		IRVersion: catalog.IRVersion, IRSHA256: catalog.IRSHA256,
		catalogOps: map[string]*OpInfo{}, catalogEvents: map[string]*EventInfo{},
		ops: map[string]*registeredOp{}, events: map[string]*registeredEvent{},
		subs: map[string]map[*serverSub]struct{}{},
	}
	for i := range catalog.Ops {
		op := catalog.Ops[i]
		p.catalogOps[op.Name] = &op
	}
	for i := range catalog.Events {
		ev := catalog.Events[i]
		p.catalogEvents[ev.Name] = &ev
	}
	return p, nil
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

// Register serves op with h. The op must be in the catalog, inside the
// provider's namespaces (the router refuses others), not a stream op, and
// have generated validators. Its aliases come from the catalog.
func (p *Provider) Register(op string, h Handler) error {
	info := p.catalogOps[op]
	switch {
	case info == nil:
		return fmt.Errorf("pane: op %q is not in the IR catalog", op)
	case !p.Owns(op):
		return fmt.Errorf("pane: op %q is outside namespaces %v", op, p.Namespaces)
	case h == nil:
		return fmt.Errorf("pane: op %q has no handler", op)
	case info.Kind == "stream":
		return fmt.Errorf("pane: op %q is a stream op; byte streams are not implemented", op)
	case info.ValidateParams == nil || info.ValidateResult == nil:
		return fmt.Errorf("pane: op %q has no generated validators in the catalog", op)
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	names := append([]string{op}, info.Aliases...)
	for _, name := range names {
		if _, dup := p.ops[name]; dup {
			return fmt.Errorf("pane: op name %q registered twice", name)
		}
	}
	reg := &registeredOp{info: info, handle: h}
	for _, name := range names {
		p.ops[name] = reg
	}
	return nil
}

// RegisterEvent serves the event stream name. It must be in the catalog and
// inside the provider's namespaces.
func (p *Provider) RegisterEvent(name string, h EventHandler) error {
	info := p.catalogEvents[name]
	switch {
	case info == nil:
		return fmt.Errorf("pane: event %q is not in the IR catalog", name)
	case !p.Owns(name):
		return fmt.Errorf("pane: event %q is outside namespaces %v", name, p.Namespaces)
	case info.Validate == nil:
		return fmt.Errorf("pane: event %q has no generated validator in the catalog", name)
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if _, dup := p.events[name]; dup {
		return fmt.Errorf("pane: event %q registered twice", name)
	}
	p.events[name] = &registeredEvent{info: info, EventHandler: h}
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

// serveCall runs every check in a fixed order, then the handler:
// catalog lookup, token scope, path confinement, params validation, handler,
// result validation, error-code mapping. (Decisions 29 and 30 add server_only
// and gesture checks before paths, and the jti spend after validation.)
func (p *Provider) serveCall(ctx context.Context, call *Call, auth Authorizer, params json.RawMessage, logf func(string, ...any)) (json.RawMessage, error) {
	p.mu.RLock()
	reg := p.ops[call.Op]
	p.mu.RUnlock()
	if reg == nil {
		return nil, Errorf(CodeUnknownOp, "no handler for %s", call.Op)
	}
	info := reg.info
	call.Op = info.Name // an alias dispatches as its op
	if err := auth.Authorize(info.Name, info.Scope); err != nil {
		return nil, err
	}
	if len(info.Paths) > 0 {
		var roots []string
		if c := auth.Claims(); c != nil {
			roots = c.Roots
		}
		confined, err := confineParams(params, info.Paths, roots)
		if err != nil {
			return nil, err
		}
		params = confined
	}
	if err := validateRaw(params, info.ValidateParams); err != nil {
		return nil, validationWireError(CodeInvalidParams, err)
	}
	value, err := reg.handle(ctx, call, params)
	if err == nil {
		if verr := validateRaw(value, info.ValidateResult); verr != nil {
			logf("pane: %s returned an invalid result: %v", info.Name, verr)
			return nil, Errorf(CodeInternal, "internal error")
		}
		return value, nil
	}
	var e *Error
	if !errors.As(err, &e) {
		if errors.Is(err, context.Canceled) {
			return nil, Errorf(CodeCancelled, "cancelled")
		}
		logf("pane: %s failed: %v", info.Name, err)
		return nil, Errorf(CodeInternal, "internal error")
	}
	if IsRuntimeCode(e.Code) {
		return nil, e
	}
	for _, code := range info.Errors {
		if code == e.Code {
			return nil, e
		}
	}
	// Peers rely on the IR's error list; an undeclared code is a provider
	// bug, so it is logged and reported as internal.
	logf("pane: %s returned undeclared error code %q: %s", info.Name, e.Code, e.Message)
	return nil, Errorf(CodeInternal, "internal error")
}

func validateRaw(raw json.RawMessage, validate func(any) error) error {
	if len(raw) == 0 {
		raw = jsonNull
	}
	v, err := DecodeValue(raw)
	if err != nil {
		return err
	}
	return validate(v)
}

// serverSub is one subscription this side serves. Events go through a
// bounded queue drained by one goroutine, so a slow peer never blocks
// Publish. On overflow the event is dropped and the next queued event carries
// gap:true; seq counts events actually sent, so it stays contiguous
// (decision 15, Rust lane R7).
type serverSub struct {
	conn   *Conn
	id     uint64
	stream string
	filter json.RawMessage
	match  func(filter, data json.RawMessage) bool
	prov   *Provider
	ctx    context.Context
	cancel context.CancelFunc

	qmu     sync.Mutex
	dropped bool
	queue   chan queuedEvent
	quit    chan struct{}
	once    sync.Once
}

type queuedEvent struct {
	data json.RawMessage
	gap  bool
}

const serverSubQueue = 256

func (s *serverSub) enqueue(data json.RawMessage) {
	s.qmu.Lock()
	defer s.qmu.Unlock()
	select {
	case s.queue <- queuedEvent{data: data, gap: s.dropped}:
		s.dropped = false
	default:
		s.dropped = true
	}
}

func (s *serverSub) run() {
	var seq uint64
	for {
		select {
		case ev := <-s.queue:
			seq++
			if err := s.conn.send(NewEvent(s.id, seq, ev.data, ev.gap)); err != nil {
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
		s.cancel()
		s.prov.mu.Lock()
		delete(s.prov.subs[s.stream], s)
		s.prov.mu.Unlock()
	})
}

// Sink emits events to one subscription (EventHandler.OnSubscribe).
type Sink struct {
	sub      *serverSub
	validate func(any) error // from the catalog
}

// Filter is the subscription's filter, or nil.
func (k *Sink) Filter() json.RawMessage { return k.sub.filter }

// Emit validates data against the event's IR schema and queues it for this
// subscription only. It never blocks.
func (k *Sink) Emit(data json.RawMessage) error {
	if err := validateRaw(data, k.validate); err != nil {
		return validationWireError(CodeInvalidEvent, err)
	}
	k.sub.enqueue(data)
	return nil
}

// TypedSink is the generated, typed wrapper around Sink.
type TypedSink[T any] struct{ Sink *Sink }

// NewTypedSink is used by generated code.
func NewTypedSink[T any](s *Sink) *TypedSink[T] { return &TypedSink[T]{Sink: s} }

// Emit marshals v and emits it (the catalog validator runs in Sink.Emit).
func (t *TypedSink[T]) Emit(v T) error {
	raw, err := json.Marshal(v)
	if err != nil {
		return err
	}
	return t.Sink.Emit(raw)
}

// Filter is the subscription's filter, or nil.
func (t *TypedSink[T]) Filter() json.RawMessage { return t.Sink.Filter() }

// afterSubscribeReply runs right after a subscription's ok is written; tests
// use it to publish at that moment. Nil outside tests.
var afterSubscribeReply func()

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
	if err := c.auth.Authorize(ev.info.Name, ev.info.Scope); err != nil {
		_ = c.send(NewErr(id, err))
		return
	}
	if len(m.Filter) > 0 && ev.Match == nil {
		_ = c.send(NewErr(id, Errorf(CodeInvalidParams, "stream %q takes no filter", stream)))
		return
	}
	ctx, cancel := context.WithCancel(c.ctx)
	s := &serverSub{conn: c, stream: stream, filter: m.Filter, match: ev.Match, prov: p, ctx: ctx, cancel: cancel,
		queue: make(chan queuedEvent, serverSubQueue), quit: make(chan struct{})}
	c.mu.Lock()
	c.nextSub++
	s.id = c.nextSub
	c.mu.Unlock()
	if ev.OnSubscribe != nil {
		call := &Call{ID: id, Op: stream, Conn: c, Claims: c.auth.Claims()}
		if err := ev.OnSubscribe(ctx, call, &Sink{sub: s, validate: ev.info.Validate}); err != nil {
			cancel()
			_ = c.send(NewErr(id, asWireError(err)))
			return
		}
	}
	c.mu.Lock()
	c.served[s.id] = s
	c.mu.Unlock()
	// Join the provider BEFORE the ok: the ok tells the subscriber the stream
	// is live, so an event published once it holds the ok must reach it.
	// Events published from here on wait in s.queue; the sender goroutine
	// starts only after the ok is written, so no event precedes it on the wire.
	p.mu.Lock()
	if p.subs[stream] == nil {
		p.subs[stream] = map[*serverSub]struct{}{}
	}
	p.subs[stream][s] = struct{}{}
	p.mu.Unlock()
	value, _ := json.Marshal(map[string]uint64{"sub": s.id})
	if err := c.send(NewOK(id, value)); err != nil {
		s.stop() // also leaves the provider
		return
	}
	if afterSubscribeReply != nil {
		afterSubscribeReply()
	}
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
	if err := validateRaw(data, ev.info.Validate); err != nil {
		return validationWireError(CodeInvalidEvent, err)
	}
	for _, s := range targets {
		if s.match != nil && len(s.filter) > 0 && !s.match(s.filter, data) {
			continue
		}
		s.enqueue(data)
	}
	return nil
}
