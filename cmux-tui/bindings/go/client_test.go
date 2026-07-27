package cmux

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestGeneratedInventoryHasTypedMethodForEveryCommand(t *testing.T) {
	commands := AllCommandMetadata()
	if len(commands) != 83 {
		t.Fatalf("generated commands = %d, want 83", len(commands))
	}
	clientType := reflect.TypeOf((*Client)(nil))
	for _, command := range commands {
		if command.Since < 5 || command.Since > MuxProtocolVersion {
			t.Errorf("%s since = %d", command.Name, command.Since)
		}
		if command.Authority == "" {
			t.Errorf("%s has no authority", command.Name)
		}
		if _, ok := clientType.MethodByName(command.GoMethod); !ok {
			t.Errorf("%s has no typed Client.%s method", command.Name, command.GoMethod)
		}
	}
	if events := AllEventMetadata(); len(events) != 44 {
		t.Fatalf("generated events = %d, want 44", len(events))
	}
}

func TestResizeResponseRequiresNullableReservationID(t *testing.T) {
	var result ResizeSurfaceResult
	if err := json.Unmarshal([]byte(`{"accepted":true}`), &result); err == nil {
		t.Fatal("missing required nullable reservation_id decoded successfully")
	}
	if err := json.Unmarshal(
		[]byte(`{"accepted":true,"reservation_id":null}`),
		&result,
	); err != nil {
		t.Fatal(err)
	}
	if !result.Accepted || !result.ReservationID.IsNull() {
		t.Fatalf("resize result = %#v", result)
	}
}

func TestJSONMapRoundTripPreservesUint64Boundary(t *testing.T) {
	const encoded = `{"id":18446744073709551615,"data":{"value":18446744073709551615}}`
	var envelope map[string]any
	if err := decodeJSON([]byte(encoded), &envelope); err != nil {
		t.Fatal(err)
	}
	if got, ok := envelope["id"].(json.Number); !ok ||
		got.String() != "18446744073709551615" {
		t.Fatalf("id = %#v, want exact json.Number", envelope["id"])
	}
	data, err := json.Marshal(envelope["data"])
	if err != nil {
		t.Fatal(err)
	}
	var result struct {
		Value uint64 `json:"value"`
	}
	if err := decodeJSON(data, &result); err != nil {
		t.Fatal(err)
	}
	if result.Value != ^uint64(0) {
		t.Fatalf("value = %d, want %d", result.Value, ^uint64(0))
	}
	if !sameJSONValue(json.Number("18446744073709551615"), ^uint64(0)) {
		t.Fatal("request id correlation lost uint64 precision")
	}
}

func TestTypedCommandPreservesUint64RequestAndResult(t *testing.T) {
	clientConn, serverConn := net.Pipe()
	defer serverConn.Close()
	client := &Client{
		timeout: time.Second,
		conn:    &jsonLineConn{conn: clientConn, reader: bufio.NewReader(clientConn)},
	}
	defer client.Close()

	go func() {
		decoder := json.NewDecoder(serverConn)
		decoder.UseNumber()
		var request map[string]any
		if decoder.Decode(&request) != nil {
			return
		}
		_ = json.NewEncoder(serverConn).Encode(map[string]any{
			"id": request["id"],
			"ok": true,
			"data": map[string]any{
				"registry_id":        "registry",
				"generation":         "generation",
				"workspace_revision": ^uint64(0),
				"terminal_revision":  ^uint64(0),
				"pane_revision":      ^uint64(0),
				"workspaces":         []any{},
			},
		})
	}()

	result, err := client.ListWorkspaces(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if result.WorkspaceRevision == nil || *result.WorkspaceRevision != ^uint64(0) {
		t.Fatalf("workspace revision = %v", result.WorkspaceRevision)
	}
}

func TestSendOptionsPreserveNullAndFalse(t *testing.T) {
	clientConn, serverConn := net.Pipe()
	defer serverConn.Close()
	protocol := uint32(MuxProtocolVersion)
	client := &Client{
		timeout:  time.Second,
		conn:     &jsonLineConn{conn: clientConn, reader: bufio.NewReader(clientConn)},
		protocol: &protocol,
	}
	defer client.Close()

	serverDone := make(chan error, 1)
	go func() {
		var request map[string]any
		decoder := json.NewDecoder(serverConn)
		decoder.UseNumber()
		if err := decoder.Decode(&request); err != nil {
			serverDone <- err
			return
		}
		for _, field := range []string{"text", "bytes"} {
			value, exists := request[field]
			if !exists || value != nil {
				serverDone <- fmt.Errorf(
					"%s = %#v, exists = %t",
					field,
					value,
					exists,
				)
				return
			}
		}
		paste, exists := request["paste"]
		if !exists || paste != false {
			serverDone <- fmt.Errorf(
				"paste = %#v, exists = %t",
				paste,
				exists,
			)
			return
		}
		serverDone <- json.NewEncoder(serverConn).Encode(map[string]any{
			"id":   request["id"],
			"ok":   true,
			"data": map[string]any{},
		})
	}()

	paste := false
	if err := client.Send(
		context.Background(),
		9,
		SendOptions{
			Text:  Null[string](),
			Bytes: Null[Base64](),
			Paste: &paste,
		},
	); err != nil {
		t.Fatal(err)
	}
	if err := <-serverDone; err != nil {
		t.Fatal(err)
	}
}

func TestSocketResolutionUsesNormativePrecedence(t *testing.T) {
	t.Setenv("CMUX_TUI_SOCKET", "")
	t.Setenv("CMUX_MUX_SOCKET", "")
	t.Setenv("XDG_RUNTIME_DIR", "/run/user-test")
	t.Setenv("TMPDIR", "/tmp/ignored")

	path, err := ResolveSocketPath("", "main")
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(
		"/run/user-test",
		fmt.Sprintf("cmux-tui-%d", os.Getuid()),
		"main.sock",
	)
	if path != want {
		t.Fatalf("resolved path = %q, want %q", path, want)
	}

	t.Setenv("CMUX_MUX_SOCKET", "/tmp/legacy.sock")
	path, err = ResolveSocketPath("", "main")
	if err != nil || path != "/tmp/legacy.sock" {
		t.Fatalf("legacy env path = %q, %v", path, err)
	}
	t.Setenv("CMUX_TUI_SOCKET", "/tmp/current.sock")
	path, err = ResolveSocketPath("", "main")
	if err != nil || path != "/tmp/current.sock" {
		t.Fatalf("current env path = %q, %v", path, err)
	}
	path, err = ResolveSocketPath("/tmp/explicit.sock", "main")
	if err != nil || path != "/tmp/explicit.sock" {
		t.Fatalf("explicit path = %q, %v", path, err)
	}
}

func TestSocketResolutionFallsBackWhenUnixPathIsTooLong(t *testing.T) {
	t.Setenv("XDG_RUNTIME_DIR", "/"+string(bytes.Repeat([]byte{'x'}, 150)))
	t.Setenv("TMPDIR", "")
	path := DefaultSocketPath("main")
	want := filepath.Join(
		"/tmp",
		fmt.Sprintf("cmux-tui-%d", os.Getuid()),
		"main.sock",
	)
	if path != want {
		t.Fatalf("fallback path = %q, want %q", path, want)
	}
}

func TestSocketResolutionRejectsUnsafeSessionNames(t *testing.T) {
	t.Setenv("CMUX_TUI_SOCKET", "")
	t.Setenv("CMUX_MUX_SOCKET", "")
	for _, session := range []string{"", ".", "..", "../other", "contains space", "a/b"} {
		if _, err := ResolveSocketPath("", session); !errors.Is(err, ErrInvalidArgument) {
			t.Errorf("session %q error = %v, want invalid argument", session, err)
		}
	}
}

func TestClientCloseUnblocksPendingRead(t *testing.T) {
	clientConn, serverConn := net.Pipe()
	defer serverConn.Close()
	client := &Client{
		timeout: time.Hour,
		conn:    &jsonLineConn{conn: clientConn, reader: bufio.NewReader(clientConn)},
	}
	result := make(chan error, 1)
	go func() {
		_, err := client.SendRaw(
			context.Background(),
			map[string]any{"cmd": "identify"},
		)
		result <- err
	}()

	var request map[string]any
	if err := json.NewDecoder(serverConn).Decode(&request); err != nil {
		t.Fatal(err)
	}
	if err := client.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-result:
		if !errors.Is(err, ErrConnection) {
			t.Fatalf("pending read error = %v, want connection error", err)
		}
	case <-time.After(time.Second):
		t.Fatal("Client.Close did not unblock the pending read")
	}
}

func TestStreamCloseIsConcurrentSafeAndUnblocksRead(t *testing.T) {
	clientConn, serverConn := net.Pipe()
	defer serverConn.Close()
	stream := &Stream{
		timeout: time.Hour,
		conn:    &jsonLineConn{conn: clientConn, reader: bufio.NewReader(clientConn)},
	}
	result := make(chan error, 1)
	go func() {
		_, err := stream.Recv(context.Background())
		result <- err
	}()

	var wait sync.WaitGroup
	for range 16 {
		wait.Add(1)
		go func() {
			defer wait.Done()
			if err := stream.Close(); err != nil {
				t.Errorf("Close() error = %v", err)
			}
		}()
	}
	wait.Wait()
	select {
	case err := <-result:
		if !errors.Is(err, io.EOF) {
			t.Fatalf("Recv() error = %v, want EOF", err)
		}
	case <-time.After(time.Second):
		t.Fatal("Stream.Close did not unblock Recv")
	}
}

func TestBoundedLineRejectsOversizeFrames(t *testing.T) {
	reader := bufio.NewReaderSize(bytes.NewBufferString("123456789\n"), 4)
	if _, err := readBoundedLine(reader, 8); !errors.Is(err, ErrMessageTooLarge) {
		t.Fatalf("oversize error = %v, want message too large", err)
	}
}

func TestClientOptionsApplyPerClientCommandLimits(t *testing.T) {
	t.Run("request", func(t *testing.T) {
		listener, socket := testUnixListener(t)
		client, err := NewClient(Options{
			SocketPath:      socket,
			MaxRequestBytes: 128,
		})
		if err != nil {
			t.Fatal(err)
		}
		defer client.Close()
		if client.maxRequestBytes != 128 ||
			client.maxResponseBytes != MaxResponseBytes ||
			client.maxBufferedStreamEvents != MaxBufferedStreamEvents {
			t.Fatalf(
				"resolved limits = %d, %d, %d",
				client.maxRequestBytes,
				client.maxResponseBytes,
				client.maxBufferedStreamEvents,
			)
		}
		_, err = client.SendRaw(context.Background(), map[string]any{
			"cmd":     "future-command",
			"payload": strings.Repeat("x", 512),
		})
		if !errors.Is(err, ErrMessageTooLarge) {
			t.Fatalf("oversize request error = %v", err)
		}
		_ = listener.Close()
	})

	t.Run("response", func(t *testing.T) {
		listener, socket := testUnixListener(t)
		serverDone := make(chan error, 1)
		go func() {
			conn, err := listener.Accept()
			if err != nil {
				serverDone <- err
				return
			}
			defer conn.Close()
			var request map[string]any
			if err := json.NewDecoder(conn).Decode(&request); err != nil {
				serverDone <- err
				return
			}
			serverDone <- json.NewEncoder(conn).Encode(map[string]any{
				"id": request["id"],
				"ok": true,
				"data": map[string]any{
					"payload": strings.Repeat("x", 4096),
				},
			})
		}()
		client, err := NewClient(Options{
			SocketPath:       socket,
			MaxResponseBytes: 1024,
		})
		if err != nil {
			t.Fatal(err)
		}
		defer client.Close()
		_, err = client.SendRaw(
			context.Background(),
			map[string]any{"cmd": "future-command"},
		)
		if !errors.Is(err, ErrMessageTooLarge) {
			t.Fatalf("oversize response error = %v", err)
		}
		if err := <-serverDone; err != nil {
			t.Fatal(err)
		}
	})

	for _, options := range []Options{
		{SocketPath: "/unused", MaxRequestBytes: -1},
		{SocketPath: "/unused", MaxResponseBytes: -1},
		{SocketPath: "/unused", MaxBufferedStreamEvents: -1},
	} {
		if _, err := NewClient(options); !errors.Is(err, ErrInvalidArgument) {
			t.Errorf("negative limit error = %v", err)
		}
	}
}

func TestClientOptionsApplyToDedicatedStreams(t *testing.T) {
	t.Run("response", func(t *testing.T) {
		listener, socket := testUnixListener(t)
		serverDone := make(chan error, 1)
		go serveStreamHandshake(
			listener,
			[]map[string]any{{
				"event":   "tree-changed",
				"payload": strings.Repeat("x", 4096),
			}},
			false,
			serverDone,
		)
		client, err := NewClient(Options{
			SocketPath:       socket,
			MaxResponseBytes: 1024,
		})
		if err != nil {
			t.Fatal(err)
		}
		defer client.Close()
		if _, err := client.Subscribe(context.Background()); !errors.Is(
			err,
			ErrMessageTooLarge,
		) {
			t.Fatalf("oversize stream response error = %v", err)
		}
		if err := <-serverDone; err != nil {
			t.Fatal(err)
		}
	})

	t.Run("buffer", func(t *testing.T) {
		listener, socket := testUnixListener(t)
		serverDone := make(chan error, 1)
		go serveStreamHandshake(
			listener,
			[]map[string]any{
				{"event": "tree-changed"},
				{"event": "tree-changed"},
			},
			true,
			serverDone,
		)
		client, err := NewClient(Options{
			SocketPath:              socket,
			MaxBufferedStreamEvents: 1,
		})
		if err != nil {
			t.Fatal(err)
		}
		defer client.Close()
		if _, err := client.Subscribe(context.Background()); !errors.Is(
			err,
			ErrBufferFull,
		) {
			t.Fatalf("stream buffer error = %v", err)
		}
		if err := <-serverDone; err != nil &&
			!errors.Is(err, net.ErrClosed) &&
			!errors.Is(err, io.ErrClosedPipe) {
			t.Fatal(err)
		}
	})
}

func TestProtocolTenAttachIsEnabledByDefault(t *testing.T) {
	protocol := uint32(10)
	client := &Client{
		socketPath: "/does/not/exist",
		timeout:    time.Millisecond,
		protocol:   &protocol,
	}
	_, err := client.AttachSurface(context.Background(), 1)
	if errors.Is(err, ErrProtocolMismatch) {
		t.Fatalf("default attach rejected current protocol: %v", err)
	}
	if !errors.Is(err, ErrConnection) {
		t.Fatalf("attach error = %v, want connection attempt", err)
	}
}

func TestVersionedMethodFailsLocally(t *testing.T) {
	protocol := uint32(7)
	client := &Client{protocol: &protocol}
	if err := client.SetSplitRatio(context.Background(), 1, 0.5); !errors.Is(
		err,
		ErrProtocolMismatch,
	) {
		t.Fatalf("SetSplitRatio error = %v", err)
	}
}

func TestGeneratedEventDecodingAndUnknownFallback(t *testing.T) {
	event := parseEvent(map[string]any{
		"event":          "surface-resize-failed",
		"surface":        json.Number("18446744073709551615"),
		"cols":           json.Number("120"),
		"rows":           json.Number("40"),
		"error":          "browser is not responding",
		"reservation_id": nil,
		"retry_after_ms": json.Number("250"),
	})
	failed, ok := event.(SurfaceResizeFailedEvent)
	retryAfter, hasRetryAfter := failed.RetryAfterMs.Get()
	if !ok || failed.Surface != ^uint64(0) ||
		!hasRetryAfter || retryAfter != 250 {
		t.Fatalf("decoded event = %#v", event)
	}

	unknown := parseEvent(map[string]any{
		"event": "future-event",
		"seq":   json.Number("18446744073709551615"),
	})
	future, ok := unknown.(UnknownEvent)
	if !ok || future.Raw["seq"].(json.Number).String() != "18446744073709551615" {
		t.Fatalf("unknown event = %#v", unknown)
	}
	if _, ok := any(future).(ByteAttachEvent); !ok {
		t.Fatal("unknown events must survive typed stream fallbacks")
	}
}

func TestProtocolSixResizedAliasDecodes(t *testing.T) {
	event, ok := parseEvent(map[string]any{
		"event":   "resized",
		"surface": json.Number("7"),
		"cols":    json.Number("80"),
		"rows":    json.Number("24"),
		"data":    "cmVwbGF5",
	}).(ResizedEvent)
	if !ok || event.Data == nil || string(*event.Data) != "cmVwbGF5" {
		t.Fatalf("resized event = %#v", event)
	}
}

func TestGeneratedPaneAndLayoutUnionsAreTyped(t *testing.T) {
	var live Pane
	if err := json.Unmarshal(
		[]byte(`{"id":1,"name":null,"active_tab":0,"tabs":[]}`),
		&live,
	); err != nil {
		t.Fatal(err)
	}
	livePane, ok := live.AsLivePane()
	if !ok || livePane.ID != 1 {
		t.Fatalf("live pane = %#v", live)
	}

	var dead Pane
	if err := json.Unmarshal([]byte(`{"id":2,"dead":true}`), &dead); err != nil {
		t.Fatal(err)
	}
	deadPane, ok := dead.AsDeadPane()
	if !ok || deadPane.ID != 2 || !deadPane.Dead {
		t.Fatalf("dead pane = %#v", dead)
	}

	var layout Layout
	if err := json.Unmarshal(
		[]byte(`{"type":"split","split":18446744073709551615,"dir":"right","ratio":0.5,"a":{"type":"leaf","pane":1},"b":{"type":"leaf","pane":2}}`),
		&layout,
	); err != nil {
		t.Fatal(err)
	}
	split, ok := layout.AsSplit()
	if !ok || split.Split == nil || *split.Split != ^uint64(0) {
		t.Fatalf("layout = %#v", layout)
	}
	leaf := NewLayoutLeaf(LayoutLeaf{Pane: 9})
	encoded, err := json.Marshal(leaf)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(encoded, []byte(`"type":"leaf"`)) {
		t.Fatalf("encoded layout = %s", encoded)
	}
}

func testUnixListener(t *testing.T) (net.Listener, string) {
	t.Helper()
	directory, err := os.MkdirTemp("/tmp", "cmux-go-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = os.RemoveAll(directory)
	})
	socket := filepath.Join(directory, "cmux.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = listener.Close()
	})
	return listener, socket
}

func serveStreamHandshake(
	listener net.Listener,
	events []map[string]any,
	sendResponse bool,
	done chan<- error,
) {
	commandConn, err := listener.Accept()
	if err != nil {
		done <- err
		return
	}
	defer commandConn.Close()
	streamConn, err := listener.Accept()
	if err != nil {
		done <- err
		return
	}
	defer streamConn.Close()
	var request map[string]any
	if err := json.NewDecoder(streamConn).Decode(&request); err != nil {
		done <- err
		return
	}
	encoder := json.NewEncoder(streamConn)
	for _, event := range events {
		if err := encoder.Encode(event); err != nil {
			done <- err
			return
		}
	}
	if sendResponse {
		if err := encoder.Encode(map[string]any{
			"id":   request["id"],
			"ok":   true,
			"data": map[string]any{},
		}); err != nil {
			done <- err
			return
		}
	}
	done <- nil
}
