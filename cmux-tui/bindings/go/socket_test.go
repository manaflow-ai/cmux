package cmux

import (
	"context"
	"errors"
	"net"
	"strings"
	"testing"

	"github.com/manaflow-ai/cmux/cmux-tui/bindings/go/internal/sessionpath"
)

func TestHighLevelValidationPreservesCause(t *testing.T) {
	t.Setenv("CMUX_TUI_SOCKET", "")
	t.Setenv("CMUX_MUX_SOCKET", "")
	_, err := resolveSocketPath("", string([]byte{'b', 0xff, 'd'}))
	if !errors.Is(err, ErrInvalidArgument) || !errors.Is(err, sessionpath.ErrInvalid) {
		t.Fatalf("error = %v, want invalid argument and sessionpath cause", err)
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
		"legacy-" + strings.Repeat("x", 200),
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
