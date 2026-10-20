//go:build windows

package cmux

import (
	"fmt"
	"os"

	"github.com/manaflow-ai/cmux/cmux-tui/bindings/go/internal/sessionpath"
)

// Windows transport support is experimental. Callers can inject DialContext
// for named pipes or test transports without importing a platform package.
func resolveSocketPath(explicit, session string) (string, error) {
	if explicit != "" {
		return explicit, nil
	}
	if inherited := envSocketPath(); inherited != "" {
		return inherited, nil
	}
	if err := sessionpath.Validate(session); err != nil {
		return "", fmt.Errorf("%w: %w", ErrInvalidArgument, err)
	}
	return defaultSocketPathForSession(session), nil
}

func defaultSocketPath(session string) string {
	if inherited := envSocketPath(); inherited != "" {
		return inherited
	}
	if err := sessionpath.Validate(session); err != nil {
		return invalidSessionSocketPath(session)
	}
	return defaultSocketPathForSession(session)
}

func defaultSocketPathForSession(session string) string {
	return `\\.\pipe\cmux-tui-` + session
}

func legacySocketPathForSession(session string) string { return "" }

func legacySocketPathForResolvedSession(resolved, session string) string { return "" }

// invalidSessionSocketPath keeps the unexported compatibility helper
// deterministic and outside named-pipe names derived from user text. It is
// not a connector route; resolveSocketPath returns ErrInvalidArgument first.
func invalidSessionSocketPath(session string) string {
	return `\\.\pipe\cmux-tui-invalid-` + sessionpath.Digest(session)
}

func envSocketPath() string {
	if socket := os.Getenv("CMUX_TUI_SOCKET"); socket != "" {
		return socket
	}
	return os.Getenv("CMUX_MUX_SOCKET")
}

// Windows uses named pipes in the high-level client. Keep this helper for
// platform-independent contract tests; it is not used to size pipe names.
func unixSocketPathCapacity(string) int { return 108 }
