//go:build !windows

package cmux

import (
	"os"
	"path/filepath"
	"strconv"
)

func defaultSocketPath(session string) string {
	if explicit := os.Getenv("CMUX_TUI_SOCKET"); explicit != "" {
		return explicit
	}
	if explicit := os.Getenv("CMUX_MUX_SOCKET"); explicit != "" {
		return explicit
	}
	if session == "" {
		session = "main"
	}
	base := os.Getenv("XDG_RUNTIME_DIR")
	if base == "" {
		base = os.TempDir()
	}
	return filepath.Join(base, "cmux-tui-"+strconv.Itoa(os.Getuid()), session+".sock")
}
