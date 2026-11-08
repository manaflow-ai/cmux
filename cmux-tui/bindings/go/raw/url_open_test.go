package raw

import (
	"context"
	"testing"
	"time"
)

func TestURLOpenSubscribeDeliversEventsOnDedicatedStream(t *testing.T) {
	listener, socket := testUnixListener(t)
	terminal := "term_0123456789abcdef0123456789abcdef"
	url := "HTTPS://github.com/login/device?state=AbC%2f"
	done := make(chan error, 1)
	go serveStreamHandshake(listener, []map[string]any{{
		"event":       "url-open",
		"request_id":  "cce119fe-1b39-48f9-90e9-5971f572821b",
		"terminal_id": terminal,
		"url":         url,
	}}, true, done)
	client, err := NewClient(Options{SocketPath: socket, Timeout: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	client.rememberNegotiation(MuxProtocolVersion, nil)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	result, err := client.URLOpenSubscribe(ctx, URLOpenSubscribeRequest{TerminalIDs: []string{terminal}})
	if err != nil {
		t.Fatal(err)
	}
	stream, ok := any(result).(*Stream)
	if !ok {
		t.Fatal("URL subscriptions must expose their event stream")
	}
	defer stream.Close()
	event, err := stream.Recv(ctx)
	if err != nil {
		t.Fatal(err)
	}
	request, ok := event.(URLOpenEvent)
	if !ok || request.TerminalID != terminal || request.URL != url {
		t.Fatalf("unexpected URL event: %#v", event)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}
