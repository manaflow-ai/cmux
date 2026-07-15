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
