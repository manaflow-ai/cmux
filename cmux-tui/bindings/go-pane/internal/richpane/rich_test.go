package richpane

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"os"
	"strings"
	"syscall"
	"testing"
	"time"

	pane "github.com/manaflow-ai/cmux/cmux-tui/bindings/go-pane"
)

// This package is generated from testdata/pane-protocol.rich.json, which uses
// schema features the seed IR does not (enums, inline objects, maps, bounded
// and unsigned integers, anyOf-null, null results, events). The tests check
// the generated validators and the typed client/provider end to end.

func validate(t *testing.T, fn func(any) error, doc string) error {
	t.Helper()
	v, err := pane.DecodeValue([]byte(doc))
	if err != nil {
		t.Fatalf("%s: %v", doc, err)
	}
	return fn(v)
}

func TestGeneratedValidators(t *testing.T) {
	good := []string{
		`{"path":"a","mode":"read"}`,
		`{"path":"a","mode":"write","cursor":null,"tags":[],"limits":{"lines":100000}}`,
		`{"path":"a","mode":"read","cursor":{"line":1,"col":-2147483648}}`,
	}
	for _, doc := range good {
		if err := validate(t, ValidateComExampleRichDocOpenParams, doc); err != nil {
			t.Errorf("%s: %v", doc, err)
		}
	}
	bad := map[string]string{
		`{"path":"a"}`:               `missing required property "mode"`,
		`{"path":"a","mode":"exec"}`: `/mode: "exec" is not one of`,
		`{"path":"a","mode":"read","cursor":{"line":0,"col":0}}`:          "/cursor/line: 0 is below minimum 1",
		`{"path":"a","mode":"read","cursor":{"line":1.5,"col":0}}`:        "/cursor/line: expected 64-bit signed integer",
		`{"path":"a","mode":"read","cursor":{"line":1,"col":2147483648}}`: "/cursor/col: 2147483648 is above maximum",
		`{"path":"a","mode":"read","tags":["x",3]}`:                       "/tags/1: expected string",
		`{"path":"a","mode":"read","limits":{"lines":100001}}`:            "/limits/lines: 100001 is above maximum 100000",
		`{"path":"a","mode":"read","limits":{"lines":-1}}`:                "/limits/lines: expected 64-bit unsigned integer",
		`{"path":"a","mode":"read","limits":{"lines":1,"x":1}}`:           `/limits: unexpected property "x"`,
		`{"path":null,"mode":"read"}`:                                     "/path: expected string, got null",
		`[]`:                                                              "/: expected object, got array",
	}
	for doc, want := range bad {
		err := validate(t, ValidateComExampleRichDocOpenParams, doc)
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%s: got %v, want %q", doc, err, want)
		}
	}
	docBad := map[string]string{
		`{"id":1,"kind":"note","meta":{},"lines":[]}`:                   `/kind: "note" is not one of`,
		`{"id":1,"kind":"doc","meta":{"a":1},"lines":[]}`:               "/meta/a: expected string",
		`{"id":18446744073709551616,"kind":"doc","meta":{},"lines":[]}`: "/id: expected 64-bit unsigned integer",
		`{"id":1,"kind":"doc","meta":{},"lines":null}`:                  "/lines: expected array, got null",
	}
	for doc, want := range docBad {
		err := validate(t, ValidateDoc, doc)
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%s: got %v, want %q", doc, err, want)
		}
	}
	if err := validate(t, ValidateDoc, `{"id":18446744073709551615,"kind":"doc","meta":{},"lines":[],"extra":{"any":[1]}}`); err != nil {
		t.Errorf("max uint64 and any extra: %v", err)
	}
}

func TestRequiredCollectionsMarshalEmpty(t *testing.T) {
	b, err := json.Marshal(Doc{ID: 1, Kind: "doc"})
	if err != nil {
		t.Fatal(err)
	}
	if string(b) != `{"id":1,"kind":"doc","meta":{},"lines":[]}` {
		t.Fatalf("got %s", b)
	}
	if err := validate(t, ValidateDoc, string(b)); err != nil {
		t.Fatal(err)
	}
}

type docs struct{ p *pane.Provider }

func (d docs) DocOpen(ctx context.Context, call *pane.Call, params ComExampleRichDocOpenParams) (Doc, error) {
	switch params.Path {
	case "missing":
		return Doc{}, &pane.Error{Code: ErrComExampleRichNotFound, Message: "no such doc"}
	case "invalid":
		return Doc{ID: 1, Kind: "not-doc"}, nil // fails result validation
	}
	doc := Doc{ID: 7, Kind: "doc", Meta: map[string]string{"mode": string(params.Mode)}}
	if err := PublishComExampleRichDocChanged(d.p, doc); err != nil {
		return Doc{}, err
	}
	return doc, nil
}

func (docs) SubscribeDocChanged(ctx context.Context, call *pane.Call, sink *pane.TypedSink[Doc]) error {
	return nil
}

func (docs) DocClose(context.Context, *pane.Call, ComExampleRichDocCloseParams) (ComExampleRichDocCloseResult, error) {
	return nil, nil
}

func socketpair(t *testing.T) (net.Conn, net.Conn) {
	fds, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	var out [2]net.Conn
	for i, fd := range fds {
		f := os.NewFile(uintptr(fd), "sp")
		out[i], err = net.FileConn(f)
		f.Close()
		if err != nil {
			t.Fatal(err)
		}
	}
	return out[0], out[1]
}

func TestTypedClientProviderAndEvents(t *testing.T) {
	p, err := NewProvider()
	if err != nil {
		t.Fatal(err)
	}
	if p.App != "com.example.rich" || p.IRSHA256 != IRSHA256 {
		t.Fatalf("provider %+v", p)
	}
	if err := RegisterComExampleRich(p, docs{p}); err != nil {
		t.Fatal(err)
	}
	a, b := socketpair(t)
	quiet := func(string, ...any) {}
	server := pane.NewConn(a, pane.ConnOptions{Provider: p, Logf: quiet})
	conn := pane.NewConn(b, pane.ConnOptions{Logf: quiet})
	go server.Serve()
	go conn.Serve()
	defer server.Close()
	defer conn.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	c := NewClient(conn).ComExampleRich()

	sub, err := c.SubscribeDocChanged(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	doc, err := c.DocOpen(ctx, ComExampleRichDocOpenParams{Path: "a", Mode: ModeWrite})
	if err != nil || doc.ID != 7 || doc.Meta["mode"] != "write" || doc.Lines == nil {
		t.Fatalf("open: %+v %v", doc, err)
	}
	ev, err := sub.Next(ctx)
	if err != nil || ev.Seq != 1 || ev.Gap || ev.Data.ID != 7 {
		t.Fatalf("event: %+v %v", ev, err)
	}
	if err := sub.Close(); err != nil {
		t.Fatal(err)
	}

	var e *pane.Error
	_, err = c.DocOpen(ctx, ComExampleRichDocOpenParams{Path: "missing", Mode: ModeRead})
	if !errors.As(err, &e) || e.Code != ErrComExampleRichNotFound {
		t.Fatalf("declared error: %v", err)
	}
	_, err = c.DocOpen(ctx, ComExampleRichDocOpenParams{Path: "invalid", Mode: ModeRead})
	if !errors.As(err, &e) || e.Code != pane.CodeInternal {
		t.Fatalf("invalid result must become internal: %v", err)
	}
	// The typed client refuses to send params the IR rejects.
	_, err = c.DocOpen(ctx, ComExampleRichDocOpenParams{Path: "a", Mode: "exec"})
	if !errors.As(err, &e) || e.Code != pane.CodeInvalidParams {
		t.Fatalf("client-side validation: %v", err)
	}
	if _, err := c.DocClose(ctx, ComExampleRichDocCloseParams{ID: 7}); err != nil {
		t.Fatalf("null result: %v", err)
	}
	// A provider result that fails the IR is caught by the client too.
	if err := PublishComExampleRichDocChanged(p, Doc{Kind: "nope"}); err == nil {
		t.Fatal("publish of invalid event data must fail")
	}
}
