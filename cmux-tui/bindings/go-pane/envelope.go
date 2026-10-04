package pane

import (
	"bytes"
	"encoding/json"
	"fmt"
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
)

// Message is one decoded envelope. Which fields are set depends on T; Decode
// checks that the fields required for T are present.
//
// Pointer fields distinguish "absent" from zero, because id 0 and seq 0 are
// valid values. Stream is raw because it is a string for sub/ev and a u32 for
// open/credit.
type Message struct {
	T         string          `json:"t"`
	ID        *uint64         `json:"id,omitempty"`
	Op        string          `json:"op,omitempty"`
	Params    json.RawMessage `json:"params,omitempty"`
	Cap       *string         `json:"cap,omitempty"`
	Value     json.RawMessage `json:"value,omitempty"`
	Code      string          `json:"code,omitempty"`
	Message   *string         `json:"message,omitempty"`
	Retryable *bool           `json:"retryable,omitempty"`
	Details   json.RawMessage `json:"details,omitempty"`
	Stream    json.RawMessage `json:"stream,omitempty"`
	Filter    json.RawMessage `json:"filter,omitempty"`
	Sub       *uint64         `json:"sub,omitempty"`
	Seq       *uint64         `json:"seq,omitempty"`
	Data      json.RawMessage `json:"data,omitempty"`
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

// NewEvent builds an event envelope.
func NewEvent(sub, seq uint64, data json.RawMessage) *Message {
	if len(data) == 0 {
		data = jsonNull
	}
	return &Message{T: TypeEvent, Sub: u64(sub), Seq: u64(seq), Data: data}
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

// Encode returns the message's JSON text.
func (m *Message) Encode() ([]byte, error) {
	if err := m.check(); err != nil {
		return nil, err
	}
	return json.Marshal(m)
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

func (m *Message) check() error {
	missing := func(field string) error {
		return fmt.Errorf("pane: %q envelope is missing %q", m.T, field)
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
	case "":
		return fmt.Errorf("pane: envelope is missing \"t\"")
	default:
		return fmt.Errorf("pane: unknown envelope type %q", m.T)
	}
	return nil
}
