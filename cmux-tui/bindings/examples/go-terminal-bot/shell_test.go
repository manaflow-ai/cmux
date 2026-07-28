package terminalbot

import (
	"strings"
	"testing"
)

func TestCompletionMarkerSurvivesChunkBoundaries(t *testing.T) {
	marker := newCompletionMarker("33333333-3333-4333-8333-333333333333")
	token := string(marker.token)
	chunks := []string{
		"prefix " + token[:10],
		token[10:] + ":2",
		"3\n",
	}
	for index, chunk := range chunks {
		status, found := marker.consume([]byte(chunk))
		if index < len(chunks)-1 && found {
			t.Fatalf("marker completed early after chunk %d", index)
		}
		if index == len(chunks)-1 && (!found || status != 23) {
			t.Fatalf("status = %d, found = %v", status, found)
		}
	}
}

func TestCommandQuotesArgumentsAndWaitsForAcknowledgement(t *testing.T) {
	marker := newCompletionMarker("mutation")
	if got, want := shellQuote("a'b"), `'a'"'"'b'`; got != want {
		t.Fatalf("shellQuote = %q, want %q", got, want)
	}
	command := marker.command([]string{"printf", "%s", "a'b"})
	if !strings.Contains(command, "IFS= read -r cmux_bot_ack") {
		t.Fatalf("command does not retain the terminal for capture: %s", command)
	}
}
