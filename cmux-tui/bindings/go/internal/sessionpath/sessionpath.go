package sessionpath

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"path/filepath"
	"unicode"
	"unicode/utf8"
)

// ErrInvalid identifies session text that cannot be one socket path component.
var ErrInvalid = errors.New(
	"session name must be a non-empty path component without separators or control characters",
)

// Validate applies the cmux-tui server's relaxed session-name contract.
func Validate(session string) error {
	if session == "" || session == "." || session == ".." || !utf8.ValidString(session) {
		return ErrInvalid
	}
	for _, character := range session {
		if character == '/' || character == '\\' || character == '\x00' ||
			unicode.IsControl(character) ||
			character == '\u0085' || character == '\u2028' || character == '\u2029' {
			return ErrInvalid
		}
	}
	return nil
}

// Digest returns a stable, collision-resistant leaf for compatibility path
// queries that cannot return an error. It must not be used to open a socket
// for an invalid session; connector paths use Validate first.
func Digest(session string) string {
	digest := sha256.Sum256([]byte(session))
	return hex.EncodeToString(digest[:])
}

// FallbackSocketPath returns the bounded, deterministic Unix-socket leaf used
// when a runtime directory plus the session name exceeds sun_path. Keep this
// in the shared package so raw and high-level clients use the same contract.
func FallbackSocketPath(session string, uid uint32) string {
	return filepath.Join("/tmp", fmt.Sprintf("cmux-tui-%d", uid), Digest(session)+".sock")
}
