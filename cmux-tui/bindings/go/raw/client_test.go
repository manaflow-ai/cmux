package raw

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
	"syscall"
	"testing"
	"time"

	"github.com/manaflow-ai/cmux/cmux-tui/bindings/go/internal/sessionpath"
)

func TestGeneratedInventoryHasTypedMethodForEveryCommand(t *testing.T) {
	commands := AllCommandMetadata()
	if len(commands) != 104 {
		t.Fatalf("generated commands = %d, want 104", len(commands))
	}
	clientType := reflect.TypeOf((*Client)(nil))
	commandNames := make(map[string]struct{}, len(commands))
	for _, command := range commands {
		commandNames[command.Name] = struct{}{}
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
	for _, name := range []string{
		"browser-frame-presented",
		"browser-key-press",
		"browser-mouse-guarded",
		"browser-wheel-guarded",
		"clear-history",
		"new-pane-right",
		"set-viewport-pane-width",
		"undo-layout",
	} {
		if _, ok := commandNames[name]; !ok {
			t.Errorf("generated command inventory is missing %s", name)
		}
	}
	if events := AllEventMetadata(); len(events) != 47 {
		t.Fatalf("generated events = %d, want 47", len(events))
	}
}

type invalidCountWriter struct {
	count int
}

func (w invalidCountWriter) Write([]byte) (int, error) {
	return w.count, nil
}

func TestWriteAllRejectsInvalidWriterCounts(t *testing.T) {
	for _, test := range []struct {
		name  string
		count int
	}{
		{name: "negative", count: -1},
		{name: "oversized", count: len([]byte("payload")) + 1},
	} {
		t.Run(test.name, func(t *testing.T) {
			err := writeAll(invalidCountWriter{count: test.count}, []byte("payload"))
			if err == nil {
				t.Fatal("writeAll returned nil for invalid writer count")
			}
			if err.Error() != "writer returned an invalid count" {
				t.Fatalf("writeAll error = %q, want invalid count error", err)
			}
		})
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

func TestMintTerminalRendererByTerminalEncodesAndDispatchesExactRequest(t *testing.T) {
	clientConn, serverConn := net.Pipe()
	defer serverConn.Close()
	protocol := uint32(MuxProtocolVersion)
	client := &Client{
		timeout:  time.Second,
		conn:     &jsonLineConn{conn: clientConn, reader: bufio.NewReader(clientConn)},
		protocol: &protocol,
	}
	defer client.Close()

	terminal := "term_0123456789abcdef0123456789abcdef"
	ttl := uint64(5000)
	requestSeen := make(chan map[string]any, 1)
	go func() {
		decoder := json.NewDecoder(serverConn)
		decoder.UseNumber()
		var request map[string]any
		if decoder.Decode(&request) != nil {
			return
		}
		requestSeen <- request
		_ = json.NewEncoder(serverConn).Encode(map[string]any{
			"id": request["id"],
			"ok": true,
			"data": map[string]any{
				"endpoint":         "/tmp/terminal.sock",
				"terminal_id":      "0123456789abcdef0123456789abcdef",
				"incarnation":      "fedcba9876543210fedcba9876543210",
				"token":            strings.Repeat("00", 32),
				"rights":           7,
				"protocol_version": 3,
				"ttl_ms":           ttl,
			},
		})
	}()

	result, err := client.MintTerminalRendererByTerminal(
		context.Background(),
		terminal,
		MintTerminalRendererByTerminalOptions{TtlMs: &ttl},
	)
	if err != nil {
		t.Fatal(err)
	}
	request := <-requestSeen
	if request["cmd"] != "mint-terminal-renderer-by-terminal" {
		t.Fatalf("command = %#v", request["cmd"])
	}
	if request["terminal"] != terminal {
		t.Fatalf("terminal = %#v", request["terminal"])
	}
	if got := request["ttl_ms"].(json.Number).String(); got != "5000" {
		t.Fatalf("ttl_ms = %s", got)
	}
	if result.ProtocolVersion != 3 || result.TtlMs != ttl {
		t.Fatalf("renderer grant = %#v", result)
	}
}

func TestProtocolTenBrowserCommandsPreserveFrameGuards(t *testing.T) {
	clientConn, serverConn := net.Pipe()
	defer serverConn.Close()
	protocol := uint32(MuxProtocolVersion)
	client := &Client{
		timeout:  time.Second,
		conn:     &jsonLineConn{conn: clientConn, reader: bufio.NewReader(clientConn)},
		protocol: &protocol,
		capabilities: map[string]struct{}{
			"browser-pointer-frame-guard-v1": {},
		},
	}
	defer client.Close()

	requests := make(chan []map[string]any, 1)
	go func() {
		decoder := json.NewDecoder(serverConn)
		decoder.UseNumber()
		values := make([]map[string]any, 0, 4)
		for range 4 {
			var request map[string]any
			if decoder.Decode(&request) != nil {
				return
			}
			values = append(values, request)
			if json.NewEncoder(serverConn).Encode(map[string]any{
				"id": request["id"], "ok": true, "data": map[string]any{},
			}) != nil {
				return
			}
		}
		requests <- values
	}()

	const maximum = ^uint64(0)
	if err := client.BrowserFramePresented(context.Background(), 7, maximum); err != nil {
		t.Fatalf("browser frame presented: %v", err)
	}
	if err := client.BrowserKeyPress(context.Background(), BrowserKeyPressRequest{
		Code: "KeyA", Key: "a", Modifiers: 1, Surface: 7,
		Text: Value("a"), WindowsVirtualKeyCode: 65,
	}); err != nil {
		t.Fatalf("browser key press: %v", err)
	}
	if err := client.BrowserMouseGuarded(context.Background(), BrowserMouseGuardedRequest{
		Button: Value("left"), ClickCount: Value(uint32(2)),
		FrameSeq: maximum - 1, Kind: "down", Surface: 7, XPx: 1.5, YPx: 2.5,
	}); err != nil {
		t.Fatalf("guarded browser mouse: %v", err)
	}
	if err := client.BrowserWheelGuarded(context.Background(), BrowserWheelGuardedRequest{
		DeltaYPx: -3.5, FrameSeq: 42, Surface: 7, XPx: 4.5, YPx: 5.5,
	}); err != nil {
		t.Fatalf("guarded browser wheel: %v", err)
	}

	got := <-requests
	if len(got) != 4 {
		t.Fatalf("browser command count = %d", len(got))
	}
	for index, expected := range []struct {
		command  string
		frameSeq string
	}{
		{"browser-frame-presented", "18446744073709551615"},
		{"browser-key-press", ""},
		{"browser-mouse-guarded", "18446744073709551614"},
		{"browser-wheel-guarded", "42"},
	} {
		if got[index]["cmd"] != expected.command {
			t.Fatalf("request %d command = %#v", index, got[index]["cmd"])
		}
		frameSeq, present := got[index]["frame_seq"]
		if expected.frameSeq == "" {
			if present {
				t.Fatalf("request %d unexpected frame_seq = %#v", index, frameSeq)
			}
			continue
		}
		number, ok := frameSeq.(json.Number)
		if !ok || number.String() != expected.frameSeq {
			t.Fatalf("request %d frame_seq = %#v", index, frameSeq)
		}
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

func TestClientSessionTriState(t *testing.T) {
	t.Setenv("CMUX_TUI_SOCKET", "")
	t.Setenv("CMUX_MUX_SOCKET", "")
	t.Setenv("XDG_RUNTIME_DIR", "/run/user-test")
	t.Setenv("TMPDIR", "")
	oldDial := dialUnixContext
	t.Cleanup(func() { dialUnixContext = oldDial })
	uid := fmt.Sprintf("cmux-tui-%d", os.Getuid())
	for _, test := range []struct {
		name    string
		options Options
		want    string
	}{
		{name: "omitted", options: Options{}, want: filepath.Join("/run/user-test", uid, "main.sock")},
		{name: "non-empty", options: Options{Session: "agent"}, want: filepath.Join("/run/user-test", uid, "agent.sock")},
		{name: "explicit empty", options: Options{SessionSet: true}},
	} {
		t.Run(test.name, func(t *testing.T) {
			var paths []string
			dialUnixContext = func(_ context.Context, path string) (net.Conn, error) {
				paths = append(paths, path)
				return nil, syscall.ENOENT
			}
			_, err := NewClient(test.options)
			if test.want == "" {
				if !errors.Is(err, ErrInvalidArgument) || len(paths) != 0 {
					t.Fatalf("explicit empty result = (%v, %q), want invalid before dial", err, paths)
				}
				return
			}
			if err == nil || len(paths) != 1 || paths[0] != test.want {
				t.Fatalf("result = (%v, %q), want one dial to %q", err, paths, test.want)
			}
		})
	}
}

func TestNewClientDoesNotProbeLegacySocketForNormalRuntimePath(t *testing.T) {
	t.Setenv("CMUX_TUI_SOCKET", "")
	t.Setenv("CMUX_MUX_SOCKET", "")
	t.Setenv("XDG_RUNTIME_DIR", "/run/user-test")
	t.Setenv("TMPDIR", "/tmp/ignored")
	oldDial := dialUnixContext
	t.Cleanup(func() { dialUnixContext = oldDial })
	var deadlines []time.Time
	dialUnixContext = func(ctx context.Context, _ string) (net.Conn, error) {
		deadline, ok := ctx.Deadline()
		if !ok {
			t.Fatal("dial context has no deadline")
		}
		deadlines = append(deadlines, deadline)
		return nil, syscall.ENOENT
	}
	_, err := NewClient(Options{Timeout: 5 * time.Millisecond})
	if err == nil || len(deadlines) != 1 {
		t.Fatalf("NewClient error = %v, dial attempts = %d, want one attempt", err, len(deadlines))
	}
}

func TestLegacyFallbackRequiresExactHashedPathProvenance(t *testing.T) {
	t.Setenv("XDG_RUNTIME_DIR", "/run/user-test")
	t.Setenv("TMPDIR", "")
	session := "main"
	uid := fmt.Sprintf("cmux-tui-hashed-%d", os.Getuid())
	leaf := sessionpath.Digest(session) + ".sock"
	legacy := legacySocketPathForSession(session)
	if got := legacySocketPathForResolvedSession(
		filepath.Join("/run/user-test", uid, leaf), session,
	); got != legacy {
		t.Fatalf("exact hashed path fallback = %q, want %q", got, legacy)
	}
	for _, path := range []string{
		filepath.Join("/run/user-test", fmt.Sprintf("cmux-tui-%d", os.Getuid()), "main.sock"),
		filepath.Join("/run/user-test", uid+"-stale", leaf),
		filepath.Join("/run/user-test", uid, sessionpath.Digest("other")+".sock"),
	} {
		if got := legacySocketPathForResolvedSession(path, session); got != "" {
			t.Fatalf("untrusted path %q installed fallback %q", path, got)
		}
	}
}

func TestSocketResolutionRejectsUnsafeSessionNames(t *testing.T) {
	t.Setenv("CMUX_TUI_SOCKET", "")
	t.Setenv("CMUX_MUX_SOCKET", "")
	for _, session := range []string{
		"",
		".",
		"..",
		"../other",
		"a/b",
		"a\\b",
		"bad\x00name",
		"bad\nname",
		"bad\u0085name",
		"bad\u2028name",
		"bad\u2029name",
	} {
		if _, err := ResolveSocketPath("", session); !errors.Is(err, ErrInvalidArgument) {
			t.Errorf("session %q error = %v, want invalid argument", session, err)
		}
	}
	if _, err := ResolveSocketPath("", string([]byte{'b', 0xff, 'd'})); !errors.Is(err, ErrInvalidArgument) {
		t.Errorf("malformed UTF-8 session was accepted")
	}
	if _, err := ResolveSocketPath("", string([]byte{'b', 0xed, 0xa0, 0x80, 'd'})); !errors.Is(err, ErrInvalidArgument) {
		t.Errorf("UTF-8 surrogate session was accepted")
	}
}

func TestDefaultSocketPathEmptySessionIsolated(t *testing.T) {
	t.Setenv("CMUX_TUI_SOCKET", "")
	t.Setenv("CMUX_MUX_SOCKET", "")
	t.Setenv("XDG_RUNTIME_DIR", "/run/user-test")
	if got, want := DefaultSocketPath(""), DefaultSocketPath("main"); got == want {
		t.Fatalf("empty compatibility path = %q, must not alias main path", got)
	}
}

func TestSocketResolutionPreservesLegacySafeSessionNames(t *testing.T) {
	t.Setenv("CMUX_TUI_SOCKET", "")
	t.Setenv("CMUX_MUX_SOCKET", "")
	t.Setenv("XDG_RUNTIME_DIR", "/run/user-test")
	for _, session := range []string{
		"contains space",
		"名前",
		"_leading",
		"-leading",
		".leading",
		"legacy:colon",
	} {
		path, err := ResolveSocketPath("", session)
		if err != nil {
			t.Fatalf("session %q rejected: %v", session, err)
		}
		if !strings.HasSuffix(path, "/"+session+".sock") {
			t.Fatalf("session %q path = %q, want suffix %q", session, path, "/"+session+".sock")
		}
	}
}

func TestLongSessionSocketPathUsesBindableDigestFallback(t *testing.T) {
	t.Setenv("CMUX_TUI_SOCKET", "")
	t.Setenv("CMUX_MUX_SOCKET", "")
	t.Setenv("XDG_RUNTIME_DIR", "/run/user/501")
	session := "legacy-" + strings.Repeat("x", 200)
	path, err := ResolveSocketPath("", session)
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(
		"/run/user/501",
		fmt.Sprintf("cmux-tui-hashed-%d", os.Getuid()),
		"e538a84493067947f7376110a6f695dd3db062b67eee939c3660c07f3f47dce2.sock",
	)
	if path != want {
		t.Fatalf("long session path = %q, want %q", path, want)
	}
	if !unixSocketPathFits(path) {
		t.Fatalf("long session path exceeds sockaddr_un: %q", path)
	}
	bindDir, err := os.MkdirTemp("/tmp", "cmux-go-long-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(bindDir) })
	leafLength := len([]byte(path)) - len([]byte(bindDir)) - 1
	if leafLength <= len(".sock") {
		t.Fatalf("temporary bind path cannot reach the canonical byte length: %q", path)
	}
	bindPath := filepath.Join(bindDir, strings.Repeat("x", leafLength-len(".sock"))+".sock")
	if len([]byte(bindPath)) != len([]byte(path)) {
		t.Fatalf("temporary bind path length = %d, want %d", len([]byte(bindPath)), len([]byte(path)))
	}
	listener, err := net.Listen("unix", bindPath)
	if err != nil {
		t.Fatalf("bind long session path %q: %v", bindPath, err)
	}
	t.Cleanup(func() {
		_ = listener.Close()
		_ = os.Remove(bindPath)
	})
}

func TestUnixSocketPathCapacityMatchesSupportedUnixFamilies(t *testing.T) {
	for _, goos := range []string{"darwin", "dragonfly", "freebsd", "netbsd", "openbsd"} {
		if got := unixSocketPathCapacity(goos); got != 104 {
			t.Fatalf("%s Unix socket path capacity = %d, want 104", goos, got)
		}
	}
	for _, goos := range []string{"linux", "solaris"} {
		if got := unixSocketPathCapacity(goos); got != 108 {
			t.Fatalf("%s Unix socket path capacity = %d, want 108", goos, got)
		}
	}
}

func TestNonASCIILongSessionUsesSharedUTF8SHA256Digest(t *testing.T) {
	t.Setenv("CMUX_TUI_SOCKET", "")
	t.Setenv("CMUX_MUX_SOCKET", "")
	t.Setenv("XDG_RUNTIME_DIR", "/run/user/501")
	session := strings.Repeat("名前", 100)
	path, err := ResolveSocketPath("", session)
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(
		"/run/user/501",
		fmt.Sprintf("cmux-tui-hashed-%d", os.Getuid()),
		"0d3fd777d54547652e50e049becfce29b81513bc248da9d22bbd37593f0d52e3.sock",
	)
	if path != want {
		t.Fatalf("non-ASCII long session path = %q, want %q", path, want)
	}
}

func TestHashedSessionFallsBackToTmpWhenRuntimeBaseIsTooLong(t *testing.T) {
	t.Setenv("CMUX_TUI_SOCKET", "")
	t.Setenv("CMUX_MUX_SOCKET", "")
	t.Setenv("XDG_RUNTIME_DIR", "/tmp/"+strings.Repeat("x", 200))
	session := "legacy-" + strings.Repeat("x", 200)
	path, err := ResolveSocketPath("", session)
	if err != nil {
		t.Fatal(err)
	}
	wantPrefix := filepath.Join(
		"/tmp",
		fmt.Sprintf("cmux-tui-hashed-%d", os.Getuid()),
	) + string(filepath.Separator)
	if !strings.HasPrefix(path, wantPrefix) {
		t.Fatalf("hashed fallback path = %q, want prefix %q", path, wantPrefix)
	}
}

func TestInvalidCompatibilityPathIsDeterministicAndIsolated(t *testing.T) {
	t.Setenv("CMUX_TUI_SOCKET", "")
	t.Setenv("CMUX_MUX_SOCKET", "")
	t.Setenv("XDG_RUNTIME_DIR", "/run/user-test")
	first := DefaultSocketPath("../escape")
	second := DefaultSocketPath("../escape")
	if first != second {
		t.Fatalf("invalid compatibility paths differ: %q != %q", first, second)
	}
	if (!strings.Contains(first, "/cmux-tui-invalid-") &&
		!strings.Contains(first, "/tmp/cmux-tui-invalid-")) ||
		!strings.HasSuffix(first, ".sock") || strings.Contains(first, "escape") {
		t.Fatalf("invalid compatibility path is not an isolated digest leaf: %q", first)
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
	options := SetSplitRatioOptions{}
	if !options.Transaction.IsAbsent() {
		t.Fatal("zero-value SetSplitRatioOptions transaction must be absent")
	}
	if err := client.SetSplitRatio(
		context.Background(), 1, 0.5, options,
	); !errors.Is(
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
