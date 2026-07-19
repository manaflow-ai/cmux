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
	"time"
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

func TestWorkspaceRegistryTypesDecode(t *testing.T) {
	var tree Tree
	if err := json.Unmarshal([]byte(`{"workspace_revision":4,"workspaces":[{"id":1,"key":"stable","name":"one","active":true,"screens":[]}]}`), &tree); err != nil {
		t.Fatal(err)
	}
	if tree.WorkspaceRevision != 4 || tree.Workspaces[0].Key != "stable" {
		t.Fatalf("tree = %#v", tree)
	}

	var placement WorkspacePlacement
	if err := json.Unmarshal([]byte(`{"workspace":1,"key":"stable","index":0,"workspace_revision":5}`), &placement); err != nil {
		t.Fatal(err)
	}
	if placement.WorkspaceRevision != 5 {
		t.Fatalf("placement = %#v", placement)
	}

	var mutation WorkspaceMutation
	if err := json.Unmarshal([]byte(`{"workspace":1,"key":"stable","workspace_revision":6}`), &mutation); err != nil {
		t.Fatal(err)
	}
	if mutation.WorkspaceRevision != 6 {
		t.Fatalf("mutation = %#v", mutation)
	}
}

func TestCreateTerminalPreservesExplicitlyEmptyArgv(t *testing.T) {
	if _, ok := commandMap(CreateTerminalOptions{})["argv"]; ok {
		t.Fatal("nil argv must remain absent for backward compatibility")
	}
	params := commandMap(CreateTerminalOptions{Argv: []string{}})
	argv, ok := params["argv"].([]any)
	if !ok || len(argv) != 0 {
		t.Fatalf("argv = %#v, want explicitly supplied empty array", params["argv"])
	}
}

func TestIdentifyCapabilityStateIsConcurrentSafe(t *testing.T) {
	clientConn, serverConn := net.Pipe()
	defer serverConn.Close()
	client := &Client{
		timeout: time.Second,
		conn:    &jsonLineConn{conn: clientConn, reader: bufio.NewReader(clientConn)},
	}
	defer client.Close()

	go func() {
		decoder := json.NewDecoder(serverConn)
		encoder := json.NewEncoder(serverConn)
		for {
			var request map[string]any
			if decoder.Decode(&request) != nil {
				return
			}
			if encoder.Encode(map[string]any{
				"id": request["id"],
				"ok": true,
				"data": map[string]any{
					"app": "cmux-tui", "version": "test", "protocol": 7,
					"capabilities": []string{"attach-initial-size"},
					"session":      "test", "pid": 1,
				},
			}) != nil {
				return
			}
		}
	}()

	var wait sync.WaitGroup
	wait.Add(2)
	go func() {
		defer wait.Done()
		for range 100 {
			if _, err := client.Identify(context.Background()); err != nil {
				t.Errorf("Identify() error = %v", err)
				return
			}
		}
	}()
	go func() {
		defer wait.Done()
		for range 10_000 {
			_ = client.hasCapability("attach-initial-size")
		}
	}()
	wait.Wait()
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
