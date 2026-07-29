package terminalbot

import (
	"strings"
	"testing"
	"time"
)

func TestCompletionScriptPreservesExactArguments(t *testing.T) {
	script := completionScript(
		[]string{"/usr/bin/printf", "%s", "quote ' newline\n dollar $"},
		"CMUX_DONE",
	)
	if !strings.Contains(script, "'quote '\"'\"' newline\n dollar $'") {
		t.Fatalf("argument was not shell quoted: %q", script)
	}
	if !strings.Contains(script, "CMUX_DONE:%d") {
		t.Fatalf("completion marker missing: %q", script)
	}
}

func TestParseCompletionUsesTheLastMarker(t *testing.T) {
	status, err := parseCompletion("CMUX_DONE:7 old\nCMUX_DONE:23\n", "CMUX_DONE")
	if err != nil {
		t.Fatal(err)
	}
	if status != 23 {
		t.Fatalf("status = %d, want 23", status)
	}
}

func TestClientTimeoutMustOutliveTerminalWait(t *testing.T) {
	_, err := New(Config{
		Argv:      []string{"/usr/bin/true"},
		Timeout:   10 * time.Second,
		IOTimeout: 10 * time.Second,
	})
	if err == nil || !strings.Contains(err.Error(), "IOTimeout must exceed Timeout") {
		t.Fatalf("New error = %v", err)
	}
}
