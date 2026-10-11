package pane

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strconv"
)

// Envelope types ("t").
const (
	TypeCall    = "call"
	TypeOK      = "ok"
	TypeErr     = "err"
	TypeSub     = "sub"
	TypeEvent   = "ev"
	TypeUnsub   = "unsub"
	TypeCancel  = "cancel"
	TypeRelease = "release"
	TypeOpen    = "open"
	TypeCredit  = "credit"
	TypeEnd     = "end"
	TypeAuth    = "auth"
	TypeBye     = "bye" // MessagePort transports only: orderly close (TS lane decision 8)
)

// MaxID is the largest request, subscription, seq or stream id (2^53-1, exact
// in every language's JSON numbers). Ids start at 1; ok/err may carry id 0,
// which is reserved for the auth reply.
const MaxID = 1<<53 - 1

// Message is one decoded envelope. Which fields are set depends on T; Decode
// checks that the fields required for T are present and in range.
//
// Pointer fields distinguish "absent" from zero. Stream is raw because it is a
// string for sub and a u32 for open/credit/end. The field order is the
// canonical encoding order shared with the Rust and TS lanes.
type Message struct {
	T         string          `json:"t"`
	ID        *uint64         `json:"id,omitempty"`
	Sub       *uint64         `json:"sub,omitempty"`
	Seq       *uint64         `json:"seq,omitempty"`
	Stream    json.RawMessage `json:"stream,omitempty"`
	Op        string          `json:"op,omitempty"`
	Params    json.RawMessage `json:"params,omitempty"`
	Cap       *string         `json:"cap,omitempty"`
	Value     json.RawMessage `json:"value,omitempty"`
	Code      string          `json:"code,omitempty"`
	Message   *string         `json:"message,omitempty"`
	Retryable *bool           `json:"retryable,omitempty"`
	Details   json.RawMessage `json:"details,omitempty"`
	Filter    json.RawMessage `json:"filter,omitempty"`
	Data      json.RawMessage `json:"data,omitempty"`
	Gap       *bool           `json:"gap,omitempty"` // only ever true on the wire
	Handle    *string         `json:"handle,omitempty"`
	Bytes     *uint32         `json:"bytes,omitempty"`
	Token     *string         `json:"token,omitempty"`
}

func u64(v uint64) *uint64 { return &v }
func str(v string) *string { return &v }

var jsonNull = json.RawMessage("null")

// NewCall builds a call envelope. params must already be JSON; nil means {}.
func NewCall(id uint64, op string, params json.RawMessage) *Message {
	if len(params) == 0 {
		params = json.RawMessage("{}")
	}
	return &Message{T: TypeCall, ID: u64(id), Op: op, Params: params}
}

// NewOK builds a result envelope. A nil value encodes as JSON null.
func NewOK(id uint64, value json.RawMessage) *Message {
	if len(value) == 0 {
		value = jsonNull
	}
	return &Message{T: TypeOK, ID: u64(id), Value: value}
}

// NewErr builds an error envelope from e.
func NewErr(id uint64, e *Error) *Message {
	retry := e.Retryable
	m := &Message{T: TypeErr, ID: u64(id), Code: e.Code, Message: str(e.Message), Retryable: &retry}
	if len(e.Details) > 0 {
		m.Details = e.Details
	}
	return m
}

// NewSub builds a subscribe envelope.
func NewSub(id uint64, stream string, filter json.RawMessage) *Message {
	raw, _ := json.Marshal(stream)
	m := &Message{T: TypeSub, ID: u64(id), Stream: raw}
	if len(filter) > 0 {
		m.Filter = filter
	}
	return m
}

// NewEvent builds an event envelope. gap marks the first event after the
// provider dropped events for this subscription (decision 15).
func NewEvent(sub, seq uint64, data json.RawMessage, gap bool) *Message {
	if len(data) == 0 {
		data = jsonNull
	}
	m := &Message{T: TypeEvent, Sub: u64(sub), Seq: u64(seq), Data: data}
	if gap {
		m.Gap = &gap
	}
	return m
}

// NewEnd builds an end envelope; a non-nil abort marks an abort.
func NewEnd(stream uint32, abort *Error) *Message {
	raw, _ := json.Marshal(stream)
	m := &Message{T: TypeEnd, Stream: raw}
	if abort != nil {
		m.Code, m.Message = abort.Code, str(abort.Message)
	}
	return m
}

// NewUnsub, NewCancel, NewRelease and NewAuth build the remaining envelopes.
func NewUnsub(sub uint64) *Message      { return &Message{T: TypeUnsub, Sub: u64(sub)} }
func NewCancel(id uint64) *Message      { return &Message{T: TypeCancel, ID: u64(id)} }
func NewRelease(handle string) *Message { return &Message{T: TypeRelease, Handle: str(handle)} }
func NewAuth(token string) *Message     { return &Message{T: TypeAuth, Token: str(token)} }

// Encode returns the message's canonical JSON text (field order as in
// Message, no HTML escaping, no trailing newline).
func (m *Message) Encode() ([]byte, error) {
	if err := m.check(); err != nil {
		return nil, err
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(m); err != nil {
		return nil, err
	}
	b := buf.Bytes()
	return b[:len(b)-1], nil
}

// PeekID returns the "id" of a message that failed to decode, when it can be
// read and is in range, so a bad_message reply can echo it; otherwise 0.
func PeekID(b []byte) uint64 {
	var v struct {
		ID json.Number `json:"id"`
	}
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.UseNumber()
	if dec.Decode(&v) != nil {
		return 0
	}
	id, err := strconv.ParseUint(v.ID.String(), 10, 64)
	if err != nil || id < 1 || id > MaxID {
		return 0
	}
	return id
}

// StreamName returns the string stream of a sub envelope.
func (m *Message) StreamName() (string, error) {
	var s string
	if err := json.Unmarshal(m.Stream, &s); err != nil {
		return "", fmt.Errorf("pane: stream is not a string: %w", err)
	}
	return s, nil
}

// StreamID returns the u32 stream of an open or credit envelope.
func (m *Message) StreamID() (uint32, error) {
	var n uint32
	if err := json.Unmarshal(m.Stream, &n); err != nil {
		return 0, fmt.Errorf("pane: stream is not a u32: %w", err)
	}
	if n == 0 {
		return 0, fmt.Errorf("pane: stream id 0 is not allowed")
	}
	return n, nil
}

// AsError converts an err envelope to *Error.
func (m *Message) AsError() *Error {
	e := &Error{Code: m.Code, Details: m.Details}
	if m.Message != nil {
		e.Message = *m.Message
	}
	if m.Retryable != nil {
		e.Retryable = *m.Retryable
	}
	return e
}

// DecodeMessage parses one envelope and checks the fields its type requires.
// Unknown fields are ignored so newer peers can add optional fields. Like the
// TS session, a call without params gets {}, and ok without value or ev
// without data gets null; params may be any JSON value at this layer (the
// op's generated validator rejects non-objects).
func DecodeMessage(b []byte) (*Message, error) {
	var m Message
	dec := json.NewDecoder(bytes.NewReader(b))
	if err := dec.Decode(&m); err != nil {
		return nil, fmt.Errorf("pane: bad envelope: %w", err)
	}
	if dec.More() {
		return nil, fmt.Errorf("pane: bad envelope: trailing data")
	}
	switch m.T {
	case TypeCall:
		if len(m.Params) == 0 {
			m.Params = json.RawMessage("{}")
		}
	case TypeOK:
		if len(m.Value) == 0 {
			m.Value = jsonNull
		}
	case TypeEvent:
		if len(m.Data) == 0 {
			m.Data = jsonNull
		}
	}
	if err := m.check(); err != nil {
		return nil, err
	}
	return &m, nil
}

func isObject(raw json.RawMessage) bool {
	t := bytes.TrimLeft(raw, " \t\r\n")
	return len(t) > 0 && t[0] == '{'
}

func inRange(name string, v *uint64, min uint64) error {
	if v != nil && (*v < min || *v > MaxID) {
		return fmt.Errorf("pane: %s %d is outside %d..2^53-1", name, *v, min)
	}
	return nil
}

func (m *Message) check() error {
	missing := func(field string) error {
		return fmt.Errorf("pane: %q envelope is missing %q", m.T, field)
	}
	idMin := uint64(1)
	if m.T == TypeOK || m.T == TypeErr {
		idMin = 0 // the auth reply
	}
	if err := inRange("id", m.ID, idMin); err != nil {
		return err
	}
	if err := inRange("sub", m.Sub, 1); err != nil {
		return err
	}
	if err := inRange("seq", m.Seq, 1); err != nil {
		return err
	}
	switch m.T {
	case TypeCall:
		if m.ID == nil {
			return missing("id")
		}
		if m.Op == "" {
			return missing("op")
		}
		if len(m.Params) == 0 {
			return missing("params")
		}
	case TypeOK:
		if m.ID == nil {
			return missing("id")
		}
		if len(m.Value) == 0 {
			return missing("value")
		}
	case TypeErr:
		if m.ID == nil {
			return missing("id")
		}
		if m.Code == "" {
			return missing("code")
		}
		if m.Message == nil {
			return missing("message")
		}
		if m.Retryable == nil {
			return missing("retryable")
		}
		if len(m.Details) > 0 && !isObject(m.Details) {
			return fmt.Errorf("pane: err details must be an object")
		}
	case TypeSub:
		if m.ID == nil {
			return missing("id")
		}
		if len(m.Stream) == 0 {
			return missing("stream")
		}
		if _, err := m.StreamName(); err != nil {
			return err
		}
		if len(m.Filter) > 0 && !isObject(m.Filter) {
			return fmt.Errorf("pane: sub filter must be an object")
		}
	case TypeEvent:
		if m.Sub == nil {
			return missing("sub")
		}
		if m.Seq == nil {
			return missing("seq")
		}
		if len(m.Data) == 0 {
			return missing("data")
		}
		if m.Gap != nil && !*m.Gap {
			m.Gap = nil // "gap":false is the same as absent
		}
	case TypeUnsub:
		if m.Sub == nil {
			return missing("sub")
		}
	case TypeCancel:
		if m.ID == nil {
			return missing("id")
		}
	case TypeRelease:
		if m.Handle == nil {
			return missing("handle")
		}
	case TypeOpen:
		if m.ID == nil {
			return missing("id")
		}
		if len(m.Stream) == 0 {
			return missing("stream")
		}
		if _, err := m.StreamID(); err != nil {
			return err
		}
		if m.Op == "" {
			return missing("op")
		}
	case TypeCredit:
		if len(m.Stream) == 0 {
			return missing("stream")
		}
		if _, err := m.StreamID(); err != nil {
			return err
		}
		if m.Bytes == nil {
			return missing("bytes")
		}
	case TypeEnd:
		if len(m.Stream) == 0 {
			return missing("stream")
		}
		if _, err := m.StreamID(); err != nil {
			return err
		}
	case TypeAuth:
		if m.Token == nil || *m.Token == "" {
			return missing("token")
		}
	case TypeBye:
	case "":
		return fmt.Errorf("pane: envelope is missing \"t\"")
	default:
		return fmt.Errorf("pane: unknown envelope type %q", m.T)
	}
	return nil
}
