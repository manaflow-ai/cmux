package pane

import (
	"context"
	"encoding/json"
	"testing"
)

// After a drop, the next queued event carries gap:true, and seq (assigned at
// send time) stays contiguous (decision 15, Rust lane R7).
func TestSubscriberOverflowMarksGap(t *testing.T) {
	s := &serverSub{queue: make(chan queuedEvent, 1)}
	s.enqueue(json.RawMessage(`1`))
	s.enqueue(json.RawMessage(`2`)) // dropped: the queue is full
	first := <-s.queue
	if first.gap || string(first.data) != "1" {
		t.Fatalf("first %+v", first)
	}
	s.enqueue(json.RawMessage(`3`))
	next := <-s.queue
	if !next.gap || string(next.data) != "3" {
		t.Fatalf("event after the drop must carry gap: %+v", next)
	}
	s.enqueue(json.RawMessage(`4`))
	if after := <-s.queue; after.gap {
		t.Fatalf("gap must clear: %+v", after)
	}
}

func TestAliasDispatchesToItsOp(t *testing.T) {
	tp := newTestProvider(t)
	if err := tp.Register("test.alias.target", echo("fast")); err != nil {
		t.Fatal(err)
	}
	if err := tp.Register("test.alias.other", echo("x")); err == nil {
		t.Fatal("duplicate alias accepted")
	}
	c := pair(t, tp)
	v, err := c.Call(context.Background(), "short.name", nil)
	if err != nil || string(v) != `{"op":"fast"}` {
		t.Fatalf("%s %v", v, err)
	}
}

// A path-taking op is refused on a connection without a token (the router
// connection): no roots means no path, fail closed.
func TestPathOpNeedsRootsEvenFromRouter(t *testing.T) {
	tp := newTestProvider(t)
	if err := tp.Register("test.fs.stat", echo("fast")); err != nil {
		t.Fatal(err)
	}
	c := pair(t, tp)
	_, err := c.Call(context.Background(), "test.fs.stat", map[string]string{"path": "/"})
	wantCode(t, err, CodeForbidden)
}

// The runtime, not the handler, validates params and results from the
// catalog, so a hand-written handler cannot skip either check.
func TestRuntimeValidatesParamsAndResults(t *testing.T) {
	tp := newTestProvider(t)
	ran := make(chan struct{}, 4)
	result := json.RawMessage(`"ok"`)
	if err := tp.Register("test.typed.op", func(context.Context, *Call, json.RawMessage) (json.RawMessage, error) {
		ran <- struct{}{}
		return result, nil
	}); err != nil {
		t.Fatal(err)
	}
	c := pair(t, tp)
	ctx := context.Background()
	_, err := c.Call(ctx, "test.typed.op", map[string]int{"x": 1})
	wantCode(t, err, CodeInvalidParams)
	select {
	case <-ran:
		t.Fatal("handler ran with invalid params")
	default:
	}
	if v, err := c.Call(ctx, "test.typed.op", map[string]int{"n": 1}); err != nil || string(v) != `"ok"` {
		t.Fatalf("valid call: %s %v", v, err)
	}
	result = json.RawMessage(`5`) // not a string: the result validator refuses it
	_, err = c.Call(ctx, "test.typed.op", map[string]int{"n": 1})
	wantCode(t, err, CodeInternal)
}

func TestRegisterRefusesOpsTheCatalogCannotEnforce(t *testing.T) {
	tp := newTestProvider(t)
	for _, name := range []string{"test.not.in_catalog", "test.stream.op", "test.unvalidated.op"} {
		if err := tp.Register(name, echo("x")); err == nil {
			t.Errorf("%s registered", name)
		}
	}
	if _, err := NewProvider("test", nil, "test"); err == nil {
		t.Fatal("a provider without a catalog was created")
	}
}
