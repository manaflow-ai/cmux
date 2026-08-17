package cmux

import (
	"context"
	"errors"
	"net"
	"strings"
	"testing"
)

func TestHighLevelClientRejectsUnsafeSessionBeforeDial(t *testing.T) {
	t.Setenv("CMUX_TUI_SOCKET", "")
	t.Setenv("CMUX_MUX_SOCKET", "")
	called := false
	_, err := NewClient(context.Background(), ClientOptions{
		Session: "../escape",
		DialContext: func(context.Context, string, string) (net.Conn, error) {
			called = true
			return nil, errors.New("dial must not run")
		},
	})
	if !errors.Is(err, ErrInvalidArgument) {
		t.Fatalf("unsafe session error = %v, want invalid argument", err)
	}
	if called {
		t.Fatal("unsafe session reached the dialer")
	}
}

func TestHighLevelSocketPathPreservesLegacySafeNames(t *testing.T) {
	t.Setenv("CMUX_TUI_SOCKET", "")
	t.Setenv("CMUX_MUX_SOCKET", "")
	t.Setenv("XDG_RUNTIME_DIR", "/run/user-test")
	for _, session := range []string{
		"contains space",
		"名前",
		"-leading",
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
