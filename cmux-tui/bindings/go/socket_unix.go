//go:build !windows

package cmux

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strconv"

	"github.com/manaflow-ai/cmux/cmux-tui/bindings/go/internal/sessionpath"
)

// resolveSocketPath applies explicit, environment, then session discovery.
// Explicit and inherited socket paths are already authoritative and therefore
// do not contain a session component to validate.
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
	base := os.Getenv("XDG_RUNTIME_DIR")
	if base == "" {
		base = os.Getenv("TMPDIR")
	}
	if base == "" {
		base = "/tmp"
	}
	fileName := session + ".sock"
	preferred := filepath.Join(base, "cmux-tui-"+strconv.Itoa(os.Getuid()), fileName)
	if unixSocketPathFits(preferred) {
		return preferred
	}
	if base != "/tmp" {
		fallback := filepath.Join("/tmp", "cmux-tui-"+strconv.Itoa(os.Getuid()), fileName)
		if unixSocketPathFits(fallback) {
			return fallback
		}
	}
	hashed := filepath.Join(
		base,
		"cmux-tui-hashed-"+strconv.Itoa(os.Getuid()),
		sessionpath.Digest(session)+".sock",
	)
	if unixSocketPathFits(hashed) {
		return hashed
	}
	return filepath.Join(
		"/tmp",
		"cmux-tui-hashed-"+strconv.Itoa(os.Getuid()),
		sessionpath.Digest(session)+".sock",
	)
}

func legacySocketPathForSession(session string) string {
	path := filepath.Join("/tmp", "cmux-tui-"+strconv.Itoa(os.Getuid()), session+".sock")
	if unixSocketPathFits(path) {
		return path
	}
	return ""
}

func legacySocketPathForResolvedSession(resolved, session string) string {
	base := os.Getenv("XDG_RUNTIME_DIR")
	if base == "" {
		base = os.Getenv("TMPDIR")
	}
	if base == "" {
		base = "/tmp"
	}
	leaf := sessionpath.Digest(session) + ".sock"
	uid := "cmux-tui-hashed-" + strconv.Itoa(os.Getuid())
	preferredHashed := filepath.Join(base, uid, leaf)
	tmpHashed := filepath.Join("/tmp", uid, leaf)
	if resolved != preferredHashed && resolved != tmpHashed {
		return ""
	}
	return legacySocketPathForSession(session)
}

// invalidSessionSocketPath keeps the unexported compatibility helper
// deterministic and outside the normal runtime directory. It is not a
// connector route; resolveSocketPath returns ErrInvalidArgument first.
func invalidSessionSocketPath(session string) string {
	base := os.Getenv("XDG_RUNTIME_DIR")
	if base == "" {
		base = os.Getenv("TMPDIR")
	}
	if base == "" {
		base = "/tmp"
	}
	leaf := sessionpath.Digest(session) + ".sock"
	preferred := filepath.Join(
		base,
		"cmux-tui-invalid-"+strconv.Itoa(os.Getuid()),
		leaf,
	)
	if unixSocketPathFits(preferred) {
		return preferred
	}
	return filepath.Join(
		"/tmp",
		"cmux-tui-invalid-"+strconv.Itoa(os.Getuid()),
		leaf,
	)
}

func envSocketPath() string {
	if socket := os.Getenv("CMUX_TUI_SOCKET"); socket != "" {
		return socket
	}
	return os.Getenv("CMUX_MUX_SOCKET")
}

func unixSocketPathFits(path string) bool {
	return len([]byte(path)) < unixSocketPathCapacity(runtime.GOOS)
}

func unixSocketPathCapacity(goos string) int {
	switch goos {
	case "darwin", "dragonfly", "freebsd", "netbsd", "openbsd":
		return 104
	default:
		return 108
	}
}
