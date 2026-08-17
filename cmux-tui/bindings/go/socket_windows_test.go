//go:build windows

package cmux

import (
	"strings"
	"testing"

	"github.com/manaflow-ai/cmux/cmux-tui/bindings/go/internal/sessionpath"
)

func TestWindowsLongSessionUsesDigestPipeFallback(t *testing.T) {
	session := "legacy-" + strings.Repeat("x", 300)
	path := defaultSocketPathForSession(session)
	want := `\\.\pipe\cmux-tui-invalid-` + sessionpath.Digest(session)
	if path != want {
		t.Fatalf("long session pipe = %q, want digest fallback %q", path, want)
	}
	if len([]rune(path)) > 256 {
		t.Fatalf("named pipe path has %d characters", len([]rune(path)))
	}
}
