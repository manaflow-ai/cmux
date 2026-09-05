package main

import (
	"encoding/binary"
	"os"
	"testing"
)

func TestShellResizeFrame(t *testing.T) {
	frame := shellResizeFrame(40, 120)
	if got, want := string(frame[:len(shellResizePrefix)]), string(shellResizePrefix); got != want {
		t.Fatalf("resize prefix = %q, want %q", got, want)
	}
	if got := binary.BigEndian.Uint16(frame[len(shellResizePrefix):]); got != 40 {
		t.Fatalf("rows = %d, want 40", got)
	}
	if got := binary.BigEndian.Uint16(frame[len(shellResizePrefix)+2:]); got != 120 {
		t.Fatalf("cols = %d, want 120", got)
	}
}

func TestTerminalNameFallsBackFromUnsafeValue(t *testing.T) {
	old, present := os.LookupEnv("TERM")
	t.Cleanup(func() {
		if present {
			_ = os.Setenv("TERM", old)
		} else {
			_ = os.Unsetenv("TERM")
		}
	})
	for _, value := range []string{"", "xterm 256color", "xterm\n256color"} {
		_ = os.Setenv("TERM", value)
		if got, want := terminalName(), "xterm-256color"; got != want {
			t.Errorf("TERM=%q: terminalName() = %q, want %q", value, got, want)
		}
	}
	_ = os.Setenv("TERM", "xterm-ghostty")
	if got := terminalName(); got != "xterm-ghostty" {
		t.Fatalf("terminalName() = %q, want xterm-ghostty", got)
	}
}
