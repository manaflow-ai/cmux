package pane

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func TestEnvelopeRoundTrip(t *testing.T) {
	cases := []struct {
		msg  *Message
		wire string
	}{
		{NewCall(0, "com.example.hello.greet.say", json.RawMessage(`{"name":"a"}`)),
			`{"t":"call","id":0,"op":"com.example.hello.greet.say","params":{"name":"a"}}`},
		{NewCall(7, "cmux.git.status", nil), `{"t":"call","id":7,"op":"cmux.git.status","params":{}}`},
		{NewOK(7, json.RawMessage(`{"message":"hi"}`)), `{"t":"ok","id":7,"value":{"message":"hi"}}`},
		{NewOK(8, nil), `{"t":"ok","id":8,"value":null}`},
		{NewErr(9, &Error{Code: "cmux.git.not_a_repo", Message: "no", Retryable: false}),
			`{"t":"err","id":9,"code":"cmux.git.not_a_repo","message":"no","retryable":false}`},
		{NewErr(10, &Error{Code: CodeBusy, Message: "", Retryable: true, Details: json.RawMessage(`{"n":1}`)}),
			`{"t":"err","id":10,"code":"cmux.protocol.busy","message":"","retryable":true,"details":{"n":1}}`},
		{NewSub(11, "cmux.git.status.changed", nil), `{"t":"sub","id":11,"stream":"cmux.git.status.changed"}`},
		{NewSub(12, "cmux.git.status.changed", json.RawMessage(`{"cwd":"/"}`)),
			`{"t":"sub","id":12,"stream":"cmux.git.status.changed","filter":{"cwd":"/"}}`},
		{NewEvent(3, 0, json.RawMessage(`{"x":1}`)), `{"t":"ev","sub":3,"seq":0,"data":{"x":1}}`},
		{NewUnsub(3), `{"t":"unsub","sub":3}`},
		{NewCancel(18446744073709551615), `{"t":"cancel","id":18446744073709551615}`},
		{NewRelease("h1"), `{"t":"release","handle":"h1"}`},
		{NewAuth("tok"), `{"t":"auth","token":"tok"}`},
	}
	for _, c := range cases {
		b, err := c.msg.Encode()
		if err != nil {
			t.Fatalf("encode %s: %v", c.wire, err)
		}
		if string(b) != c.wire {
			t.Errorf("encode:\n got %s\nwant %s", b, c.wire)
		}
		back, err := DecodeMessage([]byte(c.wire))
		if err != nil {
			t.Fatalf("decode %s: %v", c.wire, err)
		}
		if !reflect.DeepEqual(back, c.msg) {
			t.Errorf("decode %s: got %+v want %+v", c.wire, back, c.msg)
		}
	}
}

func TestEnvelopeOpenCredit(t *testing.T) {
	m, err := DecodeMessage([]byte(`{"t":"open","id":3,"stream":4,"op":"com.x.blob.read","params":{"path":"a"},"cap":"h1"}`))
	if err != nil {
		t.Fatal(err)
	}
	if id, _ := m.StreamID(); id != 4 {
		t.Fatalf("stream id %d", id)
	}
	if _, err := DecodeMessage([]byte(`{"t":"credit","stream":4,"bytes":65536}`)); err != nil {
		t.Fatal(err)
	}
	if _, err := DecodeMessage([]byte(`{"t":"credit","stream":"4","bytes":1}`)); err == nil {
		t.Fatal("credit with string stream must fail")
	}
	if _, err := DecodeMessage([]byte(`{"t":"open","stream":4,"op":"com.x.blob.read"}`)); err == nil {
		t.Fatal("open without id must fail")
	}
	end, err := NewEnd(4, &Error{Code: CodeStreamAborted, Message: "gone"}).Encode()
	if err != nil || string(end) != `{"t":"end","code":"cmux.protocol.stream_aborted","message":"gone","stream":4}` {
		t.Fatalf("end: %s %v", end, err)
	}
	if _, err := DecodeMessage([]byte(`{"t":"end","stream":4294967296}`)); err == nil {
		t.Fatal("end with stream above u32 must fail")
	}
}

func TestEnvelopeRejects(t *testing.T) {
	bad := map[string]string{
		`{}`:                                    `missing "t"`,
		`{"t":"nope"}`:                          "unknown envelope type",
		`{"t":"call","op":"a.b.c","params":{}}`: `missing "id"`,
		`{"t":"call","id":1,"params":{}}`:       `missing "op"`,
		`{"t":"call","id":-1,"op":"a.b.c","params":{}}`:     "bad envelope",
		`{"t":"err","id":1,"code":"a.b","message":"m"}`:     `missing "retryable"`,
		`{"t":"err","id":1,"message":"m","retryable":true}`: `missing "code"`,
		`{"t":"sub","id":1,"stream":5}`:                     "stream is not a string",
		`{"t":"ev","sub":1,"data":{}}`:                      `missing "seq"`,
		`{"t":"auth","token":""}`:                           `missing "token"`,
		`{"t":"cancel","id":1} {}`:                          "trailing data",
		`not json`:                                          "bad envelope",
	}
	for wire, want := range bad {
		_, err := DecodeMessage([]byte(wire))
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%s: got %v, want error containing %q", wire, err, want)
		}
	}
}

func TestEnvelopeDefaults(t *testing.T) {
	// Matches the TS lane: absent params is {}, absent value/data is null.
	cases := map[string]func(*Message) string{
		`{"t":"call","id":1,"op":"a.b.c"}`:              func(m *Message) string { return string(m.Params) },
		`{"t":"ok","id":1}`:                             func(m *Message) string { return string(m.Value) },
		`{"t":"ev","sub":1,"seq":1}`:                    func(m *Message) string { return string(m.Data) },
		`{"t":"call","id":1,"op":"a.b.c","params":[1]}`: func(m *Message) string { return string(m.Params) },
	}
	want := map[string]string{
		`{"t":"call","id":1,"op":"a.b.c"}`: "{}", `{"t":"ok","id":1}`: "null",
		`{"t":"ev","sub":1,"seq":1}`: "null", `{"t":"call","id":1,"op":"a.b.c","params":[1]}`: "[1]",
	}
	for wire, get := range cases {
		m, err := DecodeMessage([]byte(wire))
		if err != nil {
			t.Fatalf("%s: %v", wire, err)
		}
		if got := get(m); got != want[wire] {
			t.Errorf("%s: got %s want %s", wire, got, want[wire])
		}
	}
	if _, err := DecodeMessage([]byte(`{"t":"call","id":1,"op":"a.b.c","cap":5}`)); err == nil {
		t.Fatal("non-string cap accepted")
	}
}

func TestEnvelopeIgnoresUnknownFields(t *testing.T) {
	m, err := DecodeMessage([]byte(`{"t":"cancel","id":5,"future":true}`))
	if err != nil || *m.ID != 5 {
		t.Fatalf("got %+v %v", m, err)
	}
}
