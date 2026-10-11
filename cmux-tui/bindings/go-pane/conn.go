package pane

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"sync"
	"sync/atomic"
)

// Authorizer decides whether the peer on a connection may use an op or
// stream. The router connection trusts the router (it already checked the
// caller's grants); direct data-plane connections check the peer's capability
// token on every call.
type Authorizer interface {
	Authorize(op, scope string) *Error
	// Claims returns the peer's verified token claims, or nil.
	Claims() *Claims
}

// TrustPeer authorizes everything. Use it only for the router connection.
type TrustPeer struct{}

func (TrustPeer) Authorize(string, string) *Error { return nil }
func (TrustPeer) Claims() *Claims                 { return nil }

// Call describes one incoming call to a handler.
type Call struct {
	ID     uint64
	Op     string
	Cap    string  // optional capability handle from the envelope ("" when absent)
	Conn   *Conn   // the caller's connection; handlers may call back on it
	Claims *Claims // verified token claims; nil on the router connection
}

// Event is one event delivered to a client subscription. Seq increases by one
// per event the provider sent to this subscription (it is contiguous). Gap is
// true on the first event after the provider dropped events for a slow
// consumer (decision 15), or after this client's own buffer overflowed; the
// consumer should resync.
type Event struct {
	Seq  uint64
	Gap  bool
	Data json.RawMessage
}

// Role says which side of a connection this peer is. It decides stream id
// parity: the connecting side opens odd stream ids, the accepting side even
// ones (TS lane decision 3).
type Role int

const (
	// RoleConnecting is the side that dialed (a page, or a provider on its
	// router connection).
	RoleConnecting Role = iota
	// RoleAccepting is the side that accepted (a provider's direct
	// listeners).
	RoleAccepting
)

// DefaultMaxInflight bounds concurrent incoming calls per connection.
const DefaultMaxInflight = 256

type pendingCall struct {
	reply chan *Message
	sub   *Subscription // non-nil for a sub request
}

type inflightCall struct {
	cancel    context.CancelFunc
	cancelled atomic.Bool
}

// Conn is one framed, symmetric pane-protocol connection. Both peers may call
// and subscribe. Incoming calls run concurrently and their results are sent
// as they finish, in any order.
type Conn struct {
	tr   Transport
	prov *Provider
	auth Authorizer
	role Role
	logf func(string, ...any)

	wmu sync.Mutex

	nextID  atomic.Uint64
	mu      sync.Mutex
	pending map[uint64]*pendingCall
	inflt   map[uint64]*inflightCall
	served  map[uint64]*serverSub // subscriptions this side serves
	clients map[uint64]*Subscription
	nextSub uint64
	sem     chan struct{}

	ctx       context.Context
	cancelAll context.CancelFunc
	closeOnce sync.Once
	done      chan struct{}
	closeErr  error
}

// ConnOptions configure NewConn.
type ConnOptions struct {
	// Provider serves incoming calls and subscriptions; nil means this side
	// serves nothing (a pure client) and answers cmux.unknown_op.
	Provider *Provider
	// Auth defaults to TrustPeer.
	Auth Authorizer
	// MaxInflight defaults to DefaultMaxInflight.
	MaxInflight int
	// Logf defaults to log.Printf.
	Logf func(string, ...any)
	// Role defaults to RoleConnecting.
	Role Role
}

// NewConn wraps a unix-socket (or any byte stream) connection using the
// 4-byte length-prefixed framing. Call Serve (usually in a goroutine) to
// start reading.
func NewConn(rw io.ReadWriteCloser, opts ConnOptions) *Conn {
	return NewTransportConn(FramedTransport(rw), opts)
}

// NewTransportConn wraps any message transport (framed unix socket,
// WebSocket, in-memory).
func NewTransportConn(tr Transport, opts ConnOptions) *Conn {
	if opts.Auth == nil {
		opts.Auth = TrustPeer{}
	}
	if opts.MaxInflight <= 0 {
		opts.MaxInflight = DefaultMaxInflight
	}
	if opts.Logf == nil {
		opts.Logf = log.Printf
	}
	ctx, cancel := context.WithCancel(context.Background())
	return &Conn{
		tr: tr, prov: opts.Provider, auth: opts.Auth, role: opts.Role, logf: opts.Logf,
		pending: map[uint64]*pendingCall{}, inflt: map[uint64]*inflightCall{},
		served: map[uint64]*serverSub{}, clients: map[uint64]*Subscription{},
		sem: make(chan struct{}, opts.MaxInflight),
		ctx: ctx, cancelAll: cancel, done: make(chan struct{}),
	}
}

// Done is closed when the connection has closed.
func (c *Conn) Done() <-chan struct{} { return c.done }

// Err returns why the connection closed (nil while open, io.EOF on a clean
// peer close).
func (c *Conn) Err() error {
	select {
	case <-c.done:
		return c.closeErr
	default:
		return nil
	}
}

// Close closes the connection, fails pending calls with cmux.closed, cancels
// incoming calls, and ends subscriptions.
func (c *Conn) Close() error { c.shutdown(errors.New("pane: connection closed locally")); return nil }

func (c *Conn) shutdown(err error) {
	c.closeOnce.Do(func() {
		c.closeErr = err
		c.cancelAll()
		_ = c.tr.Close()
		c.mu.Lock()
		pending := c.pending
		c.pending = map[uint64]*pendingCall{}
		served := c.served
		c.served = map[uint64]*serverSub{}
		clients := c.clients
		c.clients = map[uint64]*Subscription{}
		c.mu.Unlock()
		for _, p := range pending {
			close(p.reply)
		}
		for _, s := range served {
			s.stop()
		}
		for _, s := range clients {
			s.closeLocal()
		}
		close(c.done)
	})
}

// send encodes and writes one message. Frames are written under one lock so
// they never interleave.
func (c *Conn) send(m *Message) error {
	b, err := m.Encode()
	if err != nil {
		return err
	}
	c.wmu.Lock()
	err = c.tr.WriteMessage(b)
	c.wmu.Unlock()
	if err != nil {
		c.shutdown(fmt.Errorf("pane: write: %w", err))
	}
	return err
}

// Send writes a raw envelope. Most callers use Call, Subscribe or a
// generated client instead.
func (c *Conn) Send(m *Message) error { return c.send(m) }

// Serve reads and dispatches messages until the connection closes. It returns
// the reason (io.EOF on a clean close by the peer).
func (c *Conn) Serve() error {
	for {
		f, err := c.tr.ReadMessage()
		if errors.Is(err, ErrNotUTF8) {
			_ = c.send(NewErr(0, Errorf(CodeBadMessage, "%v", err)))
			continue
		}
		if err != nil {
			c.shutdown(err)
			return err
		}
		if f.Binary {
			c.handleData(f.Payload)
			continue
		}
		m, err := DecodeMessage(f.Payload)
		if err != nil {
			// The frame boundary is intact, so the connection stays open.
			// The reply echoes the id when it can be read and is in range
			// (decision 13, Rust lane R4).
			c.logf("pane: bad message: %v", err)
			_ = c.send(NewErr(PeekID(f.Payload), Errorf(CodeBadMessage, "%v", err)))
			continue
		}
		if m.T == TypeBye {
			c.shutdown(io.EOF)
			return io.EOF
		}
		c.dispatch(m)
	}
}

func (c *Conn) dispatch(m *Message) {
	switch m.T {
	case TypeCall:
		c.handleCall(m)
	case TypeOK, TypeErr:
		c.handleReply(m)
	case TypeCancel:
		c.mu.Lock()
		in := c.inflt[*m.ID]
		c.mu.Unlock()
		if in != nil {
			in.cancelled.Store(true)
			in.cancel()
		}
	case TypeSub:
		c.handleSub(m)
	case TypeUnsub:
		c.mu.Lock()
		s := c.served[*m.Sub]
		delete(c.served, *m.Sub)
		c.mu.Unlock()
		if s != nil {
			s.stop()
		}
	case TypeEvent:
		c.mu.Lock()
		s := c.clients[*m.Sub]
		c.mu.Unlock()
		if s != nil {
			s.deliver(Event{Seq: *m.Seq, Gap: m.Gap != nil && *m.Gap, Data: m.Data})
		}
	case TypeRelease:
		if c.prov != nil && c.prov.OnRelease != nil {
			c.prov.OnRelease(c, *m.Handle)
		}
	case TypeAuth:
		if r, ok := c.auth.(reauther); ok {
			if err := r.reauth(*m.Token); err != nil {
				_ = c.send(NewErr(0, err))
				c.shutdown(err)
			}
			return
		}
		c.logf("pane: ignoring auth on a connection that does not use tokens")
	case TypeOpen:
		stream, _ := m.StreamID()
		peerOdd := c.role == RoleAccepting // the peer connected, so it opens odd ids
		if (stream%2 == 1) != peerOdd {
			_ = c.send(NewErr(*m.ID, Errorf(CodeStreamAborted, "stream id %d has the wrong parity for the opener", stream)))
			return
		}
		// Byte streams are not implemented in this SDK yet, so no op has a
		// stream handler.
		_ = c.send(NewErr(*m.ID, Errorf(CodeUnknownOp, "no stream handler for %s", m.Op)))
	case TypeCredit, TypeEnd:
		c.logf("pane: ignoring %q: no byte streams are open", m.T)
	}
}

type reauther interface{ reauth(token string) *Error }

// handleData receives a binary data frame. No byte stream can be open in
// this SDK yet, so the frame is checked and dropped.
func (c *Conn) handleData(b []byte) {
	f, err := DecodeBinaryFrame(b)
	if err != nil {
		c.logf("pane: bad data frame: %v", err)
		return
	}
	c.logf("pane: dropping %d bytes for stream %d: no byte streams are open", len(f.Payload), f.Stream)
}

func (c *Conn) handleCall(m *Message) {
	id := *m.ID
	select {
	case c.sem <- struct{}{}:
	default:
		_ = c.send(NewErr(id, &Error{Code: CodeBusy, Message: "too many calls in flight", Retryable: true}))
		return
	}
	ctx, cancel := context.WithCancel(c.ctx)
	in := &inflightCall{cancel: cancel}
	c.mu.Lock()
	if _, dup := c.inflt[id]; dup {
		c.mu.Unlock()
		cancel()
		<-c.sem
		_ = c.send(NewErr(id, Errorf(CodeBadMessage, "call id %d is already in flight", id)))
		return
	}
	c.inflt[id] = in
	c.mu.Unlock()

	call := &Call{ID: id, Op: m.Op, Conn: c, Claims: c.auth.Claims()}
	if m.Cap != nil {
		call.Cap = *m.Cap
	}
	go func() {
		defer func() { <-c.sem }()
		value, err := c.serveCall(ctx, call, m.Params)
		c.mu.Lock()
		delete(c.inflt, id)
		c.mu.Unlock()
		cancel()
		var reply *Message
		switch {
		case in.cancelled.Load():
			reply = NewErr(id, Errorf(CodeCancelled, "cancelled by caller"))
		case err != nil:
			reply = NewErr(id, asWireError(err))
		default:
			reply = NewOK(id, value)
		}
		_ = c.send(reply)
	}()
}

func asWireError(err error) *Error {
	var e *Error
	if errors.As(err, &e) {
		return e
	}
	return Errorf(CodeInternal, "internal error")
}

func (c *Conn) serveCall(ctx context.Context, call *Call, params json.RawMessage) (value json.RawMessage, err error) {
	defer func() {
		if r := recover(); r != nil {
			c.logf("pane: handler for %s panicked: %v", call.Op, r)
			value, err = nil, Errorf(CodeInternal, "internal error")
		}
	}()
	if c.prov == nil {
		return nil, Errorf(CodeUnknownOp, "no provider on this connection")
	}
	return c.prov.serveCall(ctx, call, c.auth, params, c.logf)
}

func (c *Conn) handleReply(m *Message) {
	c.mu.Lock()
	p := c.pending[*m.ID]
	delete(c.pending, *m.ID)
	if p != nil && p.sub != nil && m.T == TypeOK {
		var v struct {
			Sub *uint64 `json:"sub"`
		}
		if err := json.Unmarshal(m.Value, &v); err == nil && v.Sub != nil {
			// Register before the reader continues so an event that
			// immediately follows the ok is not lost.
			p.sub.id = *v.Sub
			c.clients[*v.Sub] = p.sub
		}
	}
	c.mu.Unlock()
	if p == nil {
		// A late result for a call we already cancelled or timed out.
		return
	}
	p.reply <- m
}

// Call sends op with params (any JSON-marshalable value, or json.RawMessage)
// and waits for the result. On ctx cancellation it sends cancel and returns
// ctx.Err(). A protocol error is returned as *Error.
func (c *Conn) Call(ctx context.Context, op string, params any) (json.RawMessage, error) {
	raw, err := marshalParams(params)
	if err != nil {
		return nil, err
	}
	m, err := c.roundTrip(ctx, func(id uint64) *Message { return NewCall(id, op, raw) }, nil)
	if err != nil {
		return nil, err
	}
	if m.T == TypeErr {
		return nil, m.AsError()
	}
	return m.Value, nil
}

func closedErr() *Error {
	return &Error{Code: CodeClosed, Message: "connection closed", Retryable: true}
}

func marshalParams(params any) (json.RawMessage, error) {
	switch p := params.(type) {
	case nil:
		return json.RawMessage("{}"), nil
	case json.RawMessage:
		return p, nil
	default:
		return json.Marshal(p)
	}
}

func (c *Conn) roundTrip(ctx context.Context, build func(uint64) *Message, sub *Subscription) (*Message, error) {
	id := c.nextID.Add(1) // ids start at 1; 0 is reserved for connection-level errors
	p := &pendingCall{reply: make(chan *Message, 1), sub: sub}
	c.mu.Lock()
	select {
	case <-c.done:
		c.mu.Unlock()
		return nil, closedErr()
	default:
	}
	c.pending[id] = p
	c.mu.Unlock()
	if err := c.send(build(id)); err != nil {
		c.mu.Lock()
		delete(c.pending, id)
		c.mu.Unlock()
		return nil, err
	}
	select {
	case m, ok := <-p.reply:
		if !ok {
			return nil, closedErr()
		}
		return m, nil
	case <-ctx.Done():
		c.mu.Lock()
		_, still := c.pending[id]
		delete(c.pending, id)
		c.mu.Unlock()
		if still {
			_ = c.send(NewCancel(id))
		}
		return nil, ctx.Err()
	}
}

// Subscribe opens a subscription to stream. Close the returned subscription
// to send unsub.
func (c *Conn) Subscribe(ctx context.Context, stream string, filter json.RawMessage) (*Subscription, error) {
	s := &Subscription{conn: c, stream: stream, ch: make(chan Event, subscriptionBuffer), done: make(chan struct{})}
	m, err := c.roundTrip(ctx, func(id uint64) *Message { return NewSub(id, stream, filter) }, s)
	if err != nil {
		return nil, err
	}
	if m.T == TypeErr {
		return nil, m.AsError()
	}
	c.mu.Lock()
	registered := c.clients[s.id] == s
	c.mu.Unlock()
	if !registered {
		return nil, Errorf(CodeInvalidResult, "subscribe result must be {sub:<u64>}")
	}
	return s, nil
}

const subscriptionBuffer = 256

// Subscription is a client-side subscription. Events arrive on Events().
type Subscription struct {
	conn    *Conn
	stream  string
	id      uint64
	ch      chan Event
	once    sync.Once
	done    chan struct{}
	mu      sync.Mutex
	closed  bool
	dropped bool // the local buffer overflowed; mark the next event as a gap
}

// ID is the provider-assigned subscription id.
func (s *Subscription) ID() uint64 { return s.id }

// Events yields events until the subscription or connection closes. When the
// consumer falls behind by more than the buffer, events are dropped and the
// next event's Seq shows the gap.
func (s *Subscription) Events() <-chan Event { return s.ch }

func (s *Subscription) deliver(e Event) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return
	}
	if s.dropped {
		e.Gap = true
	}
	select {
	case s.ch <- e:
		s.dropped = false
	default:
		s.dropped = true
	}
}

func (s *Subscription) closeLocal() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.closed {
		s.closed = true
		close(s.ch)
	}
}

// Close sends unsub and closes Events().
func (s *Subscription) Close() error {
	var err error
	s.once.Do(func() {
		s.conn.mu.Lock()
		delete(s.conn.clients, s.id)
		s.conn.mu.Unlock()
		select {
		case <-s.conn.done:
		default:
			err = s.conn.send(NewUnsub(s.id))
		}
		s.closeLocal()
	})
	return err
}

// TypedSubscription decodes and validates each event with a generated
// validator before returning it.
type TypedSubscription[T any] struct {
	Sub      *Subscription
	validate func(any) error
}

// NewTypedSubscription is used by generated clients.
func NewTypedSubscription[T any](s *Subscription, validate func(any) error) *TypedSubscription[T] {
	return &TypedSubscription[T]{Sub: s, validate: validate}
}

// TypedEvent is one validated event.
type TypedEvent[T any] struct {
	Seq  uint64
	Gap  bool // events were dropped before this one; resync
	Data T
}

// Next waits for the next event. It returns io.EOF when the subscription
// closes, and *Error with cmux.protocol.invalid_event when the event fails
// validation.
func (t *TypedSubscription[T]) Next(ctx context.Context) (TypedEvent[T], error) {
	select {
	case e, ok := <-t.Sub.Events():
		if !ok {
			return TypedEvent[T]{}, io.EOF
		}
		v, err := DecodeAndValidate[T](e.Data, t.validate, CodeInvalidEvent)
		return TypedEvent[T]{Seq: e.Seq, Gap: e.Gap, Data: v}, err
	case <-ctx.Done():
		return TypedEvent[T]{}, ctx.Err()
	}
}

// Close unsubscribes.
func (t *TypedSubscription[T]) Close() error { return t.Sub.Close() }
