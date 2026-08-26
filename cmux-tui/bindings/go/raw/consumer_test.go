package raw_test

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	cmux "github.com/manaflow-ai/cmux/cmux-tui/bindings/go/raw"
)

func TestZeroOptionsClientAndPublicStreamAPIs(t *testing.T) {
	t.Setenv("CMUX_TUI_SOCKET", "")
	t.Setenv("CMUX_MUX_SOCKET", "")
	t.Setenv("XDG_RUNTIME_DIR", t.TempDir())
	socket := cmux.DefaultSocketPath("main")
	if err := os.MkdirAll(filepath.Dir(socket), 0o700); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()

	serverErrors := make(chan error, 8)
	go serve(listener, serverErrors)

	client, err := cmux.NewClient(cmux.Options{})
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	identified, err := client.Identify(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if identified.Protocol != cmux.MuxProtocolVersion ||
		identified.WorkspaceRevision != ^uint64(0) {
		t.Fatalf("identify = %#v", identified)
	}
	ping, err := client.Ping(ctx)
	if err != nil || !ping.Ok {
		t.Fatalf("ping = %#v, %v", ping, err)
	}

	subscription, err := client.Subscribe(ctx)
	if err != nil {
		t.Fatal(err)
	}
	event, err := subscription.RecvSubscribe(ctx)
	if err != nil || event.EventName() != "tree-changed" {
		t.Fatalf("subscribe event = %#v, %v", event, err)
	}
	if err := subscription.Close(); err != nil {
		t.Fatal(err)
	}

	attachment, err := client.AttachSurface(ctx, 9)
	if err != nil {
		t.Fatal(err)
	}
	byteEvent, err := attachment.RecvByte(ctx)
	if err != nil {
		t.Fatal(err)
	}
	state, ok := byteEvent.(cmux.VTStateEvent)
	if !ok {
		t.Fatalf("attach event type = %T", byteEvent)
	}
	decoded, err := cmux.DecodeBase64(state.Data)
	if err != nil || string(decoded) != "hello" {
		t.Fatalf("attach data = %q, %v", decoded, err)
	}
	if err := attachment.Close(); err != nil {
		t.Fatal(err)
	}

	if metadata, ok := cmux.CommandInfo("attach-surface"); !ok ||
		metadata.Authority != cmux.AuthorityFrontend ||
		metadata.GoMethod != "AttachSurface" {
		t.Fatalf("attach metadata = %#v, %v", metadata, ok)
	}
}

func serve(listener net.Listener, errorsOut chan<- error) {
	for {
		conn, err := listener.Accept()
		if err != nil {
			if !errors.Is(err, net.ErrClosed) {
				errorsOut <- err
			}
			return
		}
		go serveConnection(conn, errorsOut)
	}
}

func serveConnection(conn net.Conn, errorsOut chan<- error) {
	defer conn.Close()
	decoder := json.NewDecoder(conn)
	decoder.UseNumber()
	encoder := json.NewEncoder(conn)
	for {
		var request map[string]any
		if err := decoder.Decode(&request); err != nil {
			if !errors.Is(err, io.EOF) {
				errorsOut <- err
			}
			return
		}
		switch request["cmd"] {
		case "identify":
			if err := encoder.Encode(map[string]any{
				"id": request["id"],
				"ok": true,
				"data": map[string]any{
					"app":                "cmux-tui",
					"version":            "test",
					"protocol":           cmux.MuxProtocolVersion,
					"capabilities":       []string{"attach-initial-size"},
					"session":            "main",
					"pid":                1,
					"registry_id":        "registry",
					"generation":         "generation",
					"workspace_revision": ^uint64(0),
					"terminal_revision":  ^uint64(0),
					"daemon_handoff":     1,
				},
			}); err != nil {
				errorsOut <- err
				return
			}
		case "ping":
			if err := encoder.Encode(map[string]any{
				"id": request["id"],
				"ok": true,
				"data": map[string]any{
					"ok":       true,
					"version":  "test",
					"protocol": cmux.MuxProtocolVersion,
				},
			}); err != nil {
				errorsOut <- err
				return
			}
		case "subscribe":
			if err := encoder.Encode(map[string]any{"event": "tree-changed"}); err != nil {
				errorsOut <- err
				return
			}
			if err := encoder.Encode(map[string]any{
				"id":   request["id"],
				"ok":   true,
				"data": map[string]any{},
			}); err != nil {
				errorsOut <- err
				return
			}
		case "attach-surface":
			if err := encoder.Encode(map[string]any{
				"event":   "vt-state",
				"surface": 9,
				"cols":    80,
				"rows":    24,
				"data":    "aGVsbG8=",
			}); err != nil {
				errorsOut <- err
				return
			}
			if err := encoder.Encode(map[string]any{
				"id":   request["id"],
				"ok":   true,
				"data": map[string]any{},
			}); err != nil {
				errorsOut <- err
				return
			}
		}
	}
}
