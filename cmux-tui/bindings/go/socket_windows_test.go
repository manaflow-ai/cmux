//go:build windows

package cmux

import (
	"strings"
	"testing"
	"unicode/utf16"

	"github.com/manaflow-ai/cmux/cmux-tui/bindings/go/internal/sessionpath"
)

func TestWindowsLongSessionUsesDigestPipeFallback(t *testing.T) {
	session := "legacy-" + strings.Repeat("x", 300)
	path := defaultSocketPathForSession(session)
	want := `\\.\pipe\cmux-tui-hashed-` + sessionpath.Digest(session)
	if path != want {
		t.Fatalf("long session pipe = %q, want digest fallback %q", path, want)
	}
	if len([]rune(path)) > 256 {
		t.Fatalf("named pipe path has %d characters", len([]rune(path)))
	}
}

func TestWindowsNonBmpSessionUsesUtf16PipeLimit(t *testing.T) {
	session := strings.Repeat("😀", 200)
	path := defaultSocketPathForSession(session)
	want := `\\.\pipe\cmux-tui-hashed-` + sessionpath.Digest(session)
	if path != want {
		t.Fatalf("non-BMP session pipe = %q, want digest fallback %q", path, want)
	}
	if units := len(utf16.Encode([]rune(path))); units > 256 {
		t.Fatalf("named pipe path has %d UTF-16 code units", units)
	}
}
