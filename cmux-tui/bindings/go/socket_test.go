package cmux

import (
	"context"
	"errors"
	"net"
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
		"bad:session",
		"bad\"session",
		"bad<session",
		"bad>session",
		"bad|session",
		"bad*session",
		"bad?session",
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
