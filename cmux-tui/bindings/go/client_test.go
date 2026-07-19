package cmux

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"sync"
	"testing"
)

func TestLegacyResizeResponseDefaultsToAccepted(t *testing.T) {
	var result ResizeSurfaceResult
	if err := json.Unmarshal([]byte(`{}`), &result); err != nil {
		t.Fatal(err)
	}
	if !result.Accepted {
		t.Fatal("legacy resize response must be treated as accepted")
	}
}

func TestResizeResponsePreservesReservationIdentity(t *testing.T) {
	var result ResizeSurfaceResult
	if err := json.Unmarshal([]byte(`{"accepted":true,"reservation_id":41}`), &result); err != nil {
		t.Fatal(err)
	}
	if result.ReservationID == nil || *result.ReservationID != 41 {
		t.Fatalf("reservation id = %v, want 41", result.ReservationID)
	}
}

func TestIdentifyDetailsPreservesArtifactRevisions(t *testing.T) {
	var result IdentifyDetails
	if err := json.Unmarshal([]byte(`{"app":"cmux-tui","version":"0.1.2","build_commit":"cmux-sha","ghostty_commit":"ghostty-sha","protocol":7,"session":"main","pid":42}`), &result); err != nil {
		t.Fatal(err)
	}
	if result.BuildCommit == nil || *result.BuildCommit != "cmux-sha" {
		t.Fatalf("build commit = %v, want cmux-sha", result.BuildCommit)
	}
	if result.GhosttyCommit == nil || *result.GhosttyCommit != "ghostty-sha" {
		t.Fatalf("ghostty commit = %v, want ghostty-sha", result.GhosttyCommit)
	}
}

func TestIdentifyDetailsAcceptsMissingArtifactRevisions(t *testing.T) {
	var result IdentifyDetails
	if err := json.Unmarshal([]byte(`{"app":"cmux-tui","version":"0.1.2","protocol":7,"session":"main","pid":42}`), &result); err != nil {
		t.Fatal(err)
	}
	if result.BuildCommit != nil || result.GhosttyCommit != nil {
		t.Fatalf("artifact revisions = %v, %v; want nil", result.BuildCommit, result.GhosttyCommit)
	}
}

func TestIdentifyResultPreservesPositionalLiteralCompatibility(t *testing.T) {
	result := IdentifyResult{"cmux-tui", "0.1.2", 7, "main", 42}
	if result.Protocol != 7 || result.PID != 42 {
		t.Fatalf("legacy positional identify result = %#v", result)
	}
}

func TestSetSplitRatioRejectsServersOlderThanProtocolEight(t *testing.T) {
	protocol := uint32(7)
	client := &Client{protocol: &protocol}
	err := client.SetSplitRatio(context.Background(), 1, 0.5)
	if err == nil || !errors.Is(err, ErrProtocolMismatch) {
		t.Fatalf("SetSplitRatio() error = %v, want protocol mismatch", err)
	}
}

func TestSetSplitRatioAcceptsNewerAdditiveProtocols(t *testing.T) {
	protocol := uint32(9)
	client := &Client{protocol: &protocol}
	if err := client.requireProtocol(context.Background(), 8, "set-split-ratio"); err != nil {
		t.Fatalf("requireProtocol() error = %v, want protocol 9 accepted", err)
	}
}

func TestNewPaneRejectsServersOlderThanProtocolNine(t *testing.T) {
	protocol := uint32(8)
	client := &Client{protocol: &protocol}
	_, err := client.NewPane(context.Background(), 1, NewPaneOptions{})
	if err == nil || !errors.Is(err, ErrProtocolMismatch) {
		t.Fatalf("NewPane() error = %v, want protocol mismatch", err)
	}
}

func TestStreamYieldsBufferedOverflowOnceThenStops(t *testing.T) {
	client, server := net.Pipe()
	defer server.Close()
	stream := &Stream{
		conn:     &jsonLineConn{conn: client, reader: bufio.NewReader(client)},
		buffered: []Event{OverflowEvent{Error: "fell behind"}},
	}

	event, err := stream.Recv(context.Background())
	if err != nil {
		t.Fatalf("first Recv() error = %v", err)
	}
	if _, ok := event.(OverflowEvent); !ok {
		t.Fatalf("first Recv() event = %#v", event)
	}
	if _, err := stream.Recv(context.Background()); !errors.Is(err, io.EOF) {
		t.Fatalf("second Recv() error = %v, want io.EOF", err)
	}
}

func TestStreamCloseIsConcurrentSafe(t *testing.T) {
	client, server := net.Pipe()
	defer server.Close()
	stream := &Stream{conn: &jsonLineConn{conn: client, reader: bufio.NewReader(client)}}

	var wait sync.WaitGroup
	for range 16 {
		wait.Add(1)
		go func() {
			defer wait.Done()
			if err := stream.Close(); err != nil {
				t.Errorf("Close() error = %v", err)
			}
		}()
	}
	wait.Wait()

	if _, err := stream.Recv(context.Background()); !errors.Is(err, io.EOF) {
		t.Fatalf("Recv() error = %v, want io.EOF", err)
	}
}
