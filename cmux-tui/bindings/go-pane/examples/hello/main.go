// Command hello is the example third-party pane provider. It owns the
// namespace com.example.hello, serves com.example.hello.greet.say, and sends
// three com.example.hello.greet.ticks events to each new subscriber (the
// behavior the shared session vectors expect).
//
// Router-spawned: the router passes a connected socketpair fd and sets
// CMUX_PANE_ROUTER_FD to its number. Self-started: pass -router PATH or set
// CMUX_PANE_ROUTER_SOCKET, plus CMUX_PANE_APP_CREDENTIAL. Optionally pass
// -listen PATH (unix) and/or -ws 127.0.0.1:0 (pages) to accept direct
// data-plane peers that present a capability token.
//
//go:generate python3 ../../../codegen/pane/generate.py --write --ir ../../../../crates/cmux-pane-protocol/spec/pane-protocol.json --out hellopane --package hellopane --provider-ns com.example.hello
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strings"
	"syscall"

	pane "github.com/manaflow-ai/cmux/cmux-tui/bindings/go-pane"
	"github.com/manaflow-ai/cmux/cmux-tui/bindings/go-pane/examples/hello/hellopane"
)

// greeter implements hellopane.ComExampleHelloHandler.
type greeter struct{}

func (greeter) GreetSay(ctx context.Context, call *pane.Call, p hellopane.HelloParams) (hellopane.HelloResult, error) {
	name := strings.TrimSpace(p.Name)
	if name == "" {
		return hellopane.HelloResult{}, pane.Errorf(pane.CodeInvalidParams, "name is empty")
	}
	return hellopane.HelloResult{Message: fmt.Sprintf("hello, %s", name)}, nil
}

func (greeter) SubscribeGreetTicks(ctx context.Context, call *pane.Call, sink *pane.TypedSink[hellopane.HelloResult]) error {
	for i := 1; i <= 3; i++ {
		if err := sink.Emit(hellopane.HelloResult{Message: fmt.Sprintf("tick %d", i)}); err != nil {
			return err
		}
	}
	return nil
}

func newProvider() (*pane.Provider, error) {
	p, err := hellopane.NewProvider()
	if err != nil {
		return nil, err
	}
	if err := hellopane.RegisterComExampleHello(p, greeter{}); err != nil {
		return nil, err
	}
	return p, nil
}

func run(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("hello", flag.ContinueOnError)
	router := fs.String("router", "", "router unix socket path when self-started (default $"+pane.EnvRouterSocket+")")
	listen := fs.String("listen", "", "unix socket path for direct data-plane peers (optional)")
	ws := fs.String("ws", "", "loopback address for page WebSocket peers, e.g. 127.0.0.1:0 (optional)")
	origins := fs.String("allow-origin", "", "comma-separated page origins allowed over WebSocket (optional)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	p, err := newProvider()
	if err != nil {
		return err
	}
	opts := pane.RunOptions{RouterSocket: *router, Listen: *listen, WebSocket: *ws}
	if *origins != "" {
		opts.AllowedOrigins = strings.Split(*origins, ",")
	}
	return p.Run(ctx, opts)
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, os.Args[1:]); err != nil && !errors.Is(err, context.Canceled) {
		log.Fatalf("hello: %v", err)
	}
}
