//go:build !windows

package cmux

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

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
