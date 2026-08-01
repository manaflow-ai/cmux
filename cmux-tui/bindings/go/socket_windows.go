//go:build windows

package cmux

import (
	"os"
	"strings"
)

// Windows transport support is experimental. Callers can inject DialContext
// for named pipes or test transports without importing a platform package.
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
	session = strings.NewReplacer(`\`, "_", `/`, "_").Replace(session)
	return `\\.\pipe\cmux-tui-` + session
}
