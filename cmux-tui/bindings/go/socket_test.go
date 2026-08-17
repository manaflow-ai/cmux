package cmux

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

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

func TestDefaultSocketPathEmptySessionPreservesLegacyMain(t *testing.T) {
	t.Setenv("CMUX_TUI_SOCKET", "")
	t.Setenv("CMUX_MUX_SOCKET", "")
	t.Setenv("XDG_RUNTIME_DIR", "/run/user-test")
	if got, want := defaultSocketPath(""), defaultSocketPath("main"); got != want {
		t.Fatalf("empty compatibility path = %q, want legacy main path %q", got, want)
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
	t.Setenv("XDG_RUNTIME_DIR", "/run/user-test")
	session := "legacy-" + strings.Repeat("x", 200)
	path, err := resolveSocketPath("", session)
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(
		"/tmp",
		fmt.Sprintf("cmux-tui-hashed-%d", os.Getuid()),
		"e538a84493067947f7376110a6f695dd3db062b67eee939c3660c07f3f47dce2.sock",
	)
	if path != want {
		t.Fatalf("long session path = %q, want %q", path, want)
	}
}
