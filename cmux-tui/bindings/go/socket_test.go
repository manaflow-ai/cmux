package cmux

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/manaflow-ai/cmux/cmux-tui/bindings/go/internal/sessionpath"
)

type invalidCountConn struct{}

type zeroWriteConn struct{ invalidCountConn }

func (zeroWriteConn) Write([]byte) (int, error) { return 0, nil }

func (invalidCountConn) Read([]byte) (int, error)         { return 0, io.EOF }
func (invalidCountConn) Write([]byte) (int, error)        { return -1, nil }
func (invalidCountConn) Close() error                     { return nil }
func (invalidCountConn) LocalAddr() net.Addr              { return nil }
func (invalidCountConn) RemoteAddr() net.Addr             { return nil }
func (invalidCountConn) SetDeadline(time.Time) error      { return nil }
func (invalidCountConn) SetReadDeadline(time.Time) error  { return nil }
func (invalidCountConn) SetWriteDeadline(time.Time) error { return nil }

func TestWriteRejectsInvalidWriteCount(t *testing.T) {
	c := &Client{
		conn:            invalidCountConn{},
		timeout:         time.Second,
		maxRequestBytes: 1024,
		writer:          make(chan struct{}, 1),
		done:            make(chan struct{}),
	}
	c.writer <- struct{}{}
	mayHaveSent, fullyWritten, err := c.write(
		context.Background(),
		"test",
		map[string]any{"x": 1},
		nil,
	)
	if mayHaveSent || fullyWritten || err == nil || !strings.Contains(err.Error(), "invalid write count") {
		t.Fatalf(
			"write result = (%v, %v, %v), want invalid count without send",
			mayHaveSent,
			fullyWritten,
			err,
		)
	}
}

func TestWriteRejectsZeroProgress(t *testing.T) {
	c := &Client{
		conn:            zeroWriteConn{},
		timeout:         time.Second,
		maxRequestBytes: 1024,
		writer:          make(chan struct{}, 1),
		done:            make(chan struct{}),
	}
	c.writer <- struct{}{}
	mayHaveSent, fullyWritten, err := c.write(
		context.Background(), "test", map[string]any{"x": 1}, nil,
	)
	if mayHaveSent || fullyWritten || !errors.Is(err, io.ErrNoProgress) {
		t.Fatalf("write result = (%v, %v, %v), want no-progress without send", mayHaveSent, fullyWritten, err)
	}
}

func TestHighLevelClientSessionTriState(t *testing.T) {
	t.Setenv("CMUX_TUI_SOCKET", "")
	t.Setenv("CMUX_MUX_SOCKET", "")
	t.Setenv("XDG_RUNTIME_DIR", "/run/user-test")
	t.Setenv("TMPDIR", "")
	uid := fmt.Sprintf("cmux-tui-%d", os.Getuid())
	for _, test := range []struct {
		name    string
		options ClientOptions
		want    string
	}{
		{name: "omitted", options: ClientOptions{}, want: filepath.Join("/run/user-test", uid, "main.sock")},
		{name: "non-empty", options: ClientOptions{Session: "agent"}, want: filepath.Join("/run/user-test", uid, "agent.sock")},
		{name: "explicit empty", options: ClientOptions{SessionSet: true}},
	} {
		t.Run(test.name, func(t *testing.T) {
			var paths []string
			test.options.DialContext = func(_ context.Context, _ string, address string) (net.Conn, error) {
				paths = append(paths, address)
				return nil, syscall.ENOENT
			}
			_, err := NewClient(context.Background(), test.options)
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

func TestCloseCancellationDoesNotWaitForCleanupWriter(t *testing.T) {
	clientSide, serverSide := net.Pipe()
	defer serverSide.Close()
	c := &Client{
		conn:    clientSide,
		writer:  make(chan struct{}, 1),
		pending: make(map[string]chan pendingResponse),
		streams: make(map[StreamID]*streamRoute),
		done:    make(chan struct{}),
	}

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	started := time.Now()
	if err := c.Close(ctx); err != nil {
		t.Fatalf("Close() error = %v", err)
	}
	if elapsed := time.Since(started); elapsed > 200*time.Millisecond {
		t.Fatalf("Close() took %v, want context-bounded cleanup", elapsed)
	}
}

func TestHighLevelClientRejectsUnsafeSessionBeforeDial(t *testing.T) {
	t.Setenv("CMUX_TUI_SOCKET", "")
	t.Setenv("CMUX_MUX_SOCKET", "")
	if _, err := resolveSocketPath("", ""); !errors.Is(err, ErrInvalidArgument) {
		t.Fatalf("empty derived session error = %v, want invalid argument", err)
	}
	for _, session := range []string{
		".",
		"..",
		"../escape",
		"nested/session",
		"nested\\session",
		"bad\x00name",
		"bad\nname",
		"bad\u0085name",
		"bad\u2028name",
		"bad\u2029name",
	} {
		called := false
		_, err := NewClient(context.Background(), ClientOptions{
			Session: session,
			DialContext: func(context.Context, string, string) (net.Conn, error) {
				called = true
				return nil, errors.New("dial must not run")
			},
		})
		if !errors.Is(err, ErrInvalidArgument) {
			t.Errorf("unsafe session %q error = %v, want invalid argument", session, err)
		}
		if called {
			t.Errorf("unsafe session %q reached the dialer", session)
		}
	}

	if path, err := resolveSocketPath("/tmp/explicit.sock", "../escape"); err != nil ||
		path != "/tmp/explicit.sock" {
		t.Fatalf("explicit path with unsafe session = %q, %v", path, err)
	}
	t.Setenv("CMUX_TUI_SOCKET", "/tmp/inherited.sock")
	if path, err := resolveSocketPath("", "../escape"); err != nil ||
		path != "/tmp/inherited.sock" {
		t.Fatalf("inherited path with unsafe session = %q, %v", path, err)
	}
}

func TestHighLevelClientDoesNotProbeLegacySocketForNormalRuntimePath(t *testing.T) {
	t.Setenv("CMUX_TUI_SOCKET", "")
	t.Setenv("CMUX_MUX_SOCKET", "")
	t.Setenv("XDG_RUNTIME_DIR", "/run/user-test")
	var paths []string
	_, err := NewClient(context.Background(), ClientOptions{
		Session: "main",
		DialContext: func(_ context.Context, network, address string) (net.Conn, error) {
			if network != "unix" {
				t.Fatalf("network = %q, want unix", network)
			}
			paths = append(paths, address)
			return nil, syscall.ENOENT
		},
	})
	if err == nil || len(paths) != 1 {
		t.Fatalf("NewClient error = %v, dial paths = %q, want one path", err, paths)
	}
}

func TestHighLevelLegacyFallbackRequiresExactHashedPathProvenance(t *testing.T) {
	t.Setenv("XDG_RUNTIME_DIR", "/run/user-test")
	t.Setenv("TMPDIR", "")
	session := "main"
	uid := "cmux-tui-hashed-" + fmt.Sprint(os.Getuid())
	leaf := sessionpath.Digest(session) + ".sock"
	legacy := legacySocketPathForSession(session)
	if got := legacySocketPathForResolvedSession(
		filepath.Join("/run/user-test", uid, leaf), session,
	); got != legacy {
		t.Fatalf("exact hashed path fallback = %q, want %q", got, legacy)
	}
	if got := legacySocketPathForResolvedSession(
		filepath.Join("/run/user-test", "cmux-tui-"+fmt.Sprint(os.Getuid()), "main.sock"), session,
	); got != "" {
		t.Fatalf("normal runtime path installed fallback %q", got)
	}
}

func TestDefaultSocketPathEmptySessionIsolated(t *testing.T) {
	t.Setenv("CMUX_TUI_SOCKET", "")
	t.Setenv("CMUX_MUX_SOCKET", "")
	t.Setenv("XDG_RUNTIME_DIR", "/run/user-test")
	if got, want := defaultSocketPath(""), defaultSocketPath("main"); got == want {
		t.Fatalf("empty compatibility path = %q, must not alias main path", got)
	}
}

func TestHighLevelInvalidCompatibilityPathIsDeterministicAndIsolated(t *testing.T) {
	t.Setenv("CMUX_TUI_SOCKET", "")
	t.Setenv("CMUX_MUX_SOCKET", "")
	t.Setenv("XDG_RUNTIME_DIR", "/run/user-test")
	first := defaultSocketPath("../escape")
	second := defaultSocketPath("../escape")
	if first != second {
		t.Fatalf("invalid compatibility paths differ: %q != %q", first, second)
	}
	if (!strings.HasPrefix(first, "/run/user-test/cmux-tui-invalid-") &&
		!strings.HasPrefix(first, "/tmp/cmux-tui-invalid-")) ||
		!strings.HasSuffix(first, ".sock") || strings.Contains(first, "escape") {
		t.Fatalf("invalid compatibility path is not an isolated digest leaf: %q", first)
	}
}

func TestHighLevelSocketPathPreservesLegacySafeNames(t *testing.T) {
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
		path, err := resolveSocketPath("", session)
		if err != nil {
			t.Fatalf("session %q rejected: %v", session, err)
		}
		if !strings.HasSuffix(path, "/"+session+".sock") {
			t.Fatalf("session %q path = %q, want suffix %q", session, path, "/"+session+".sock")
		}
	}
}

func TestHighLevelLongSessionUsesSharedDigestFallback(t *testing.T) {
	t.Setenv("CMUX_TUI_SOCKET", "")
	t.Setenv("CMUX_MUX_SOCKET", "")
	t.Setenv("XDG_RUNTIME_DIR", "/run/user/501")
	session := "legacy-" + strings.Repeat("x", 200)
	path, err := resolveSocketPath("", session)
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

func TestHighLevelHashedSessionFallsBackToTmpWhenRuntimeBaseIsTooLong(t *testing.T) {
	t.Setenv("CMUX_TUI_SOCKET", "")
	t.Setenv("CMUX_MUX_SOCKET", "")
	t.Setenv("XDG_RUNTIME_DIR", "/tmp/"+strings.Repeat("x", 200))
	session := "legacy-" + strings.Repeat("x", 200)
	path, err := resolveSocketPath("", session)
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
