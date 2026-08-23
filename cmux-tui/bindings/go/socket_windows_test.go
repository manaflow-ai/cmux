//go:build windows

package cmux

import (
	"strings"
	"testing"

	"github.com/manaflow-ai/cmux/cmux-tui/bindings/go/internal/sessionpath"
)

func TestDefaultSocketPathHashesLongWindowsSession(t *testing.T) {
	session := strings.Repeat("x", 300)
	path := defaultSocketPathForSession(session)
	want := `\\.\pipe\cmux-tui-` + sessionpath.Digest(session)
	if path != want {
		t.Fatalf("path = %q, want %q", path, want)
	}
	if !namedPipePathFits(path) {
		t.Fatalf("fallback path exceeds named-pipe limit: %d", len([]rune(path)))
	}
}

func TestDefaultSocketPathKeepsSafeWindowsSession(t *testing.T) {
	session := "legacy-session"
	want := `\\.\pipe\cmux-tui-` + session
	if got := defaultSocketPathForSession(session); got != want {
		t.Fatalf("path = %q, want %q", got, want)
	}
}
