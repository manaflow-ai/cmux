package raw_test

import (
	"context"
	"reflect"
	"testing"
	"time"

	cmux "github.com/manaflow-ai/cmux/cmux-tui/bindings/go/raw"
)

func TestIdentityMetadataKeepsTheZeroArgumentRequest(t *testing.T) {
	listener, socket := externalUnixListener(t)
	seen := make(chan []map[string]any, 1)
	failure := make(chan error, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			failure <- err
			return
		}
		defer conn.Close()
		requests := make([]map[string]any, 0, 3)
		for index := 0; index < 3; index++ {
			request, err := externalReadRequest(conn)
			if err != nil {
				failure <- err
				return
			}
			requests = append(requests, request)
			result := externalIdentifyResult([]string{"machine-identity-v1"})
			if request["machine_metadata"] == true {
				result["machine_id"] = "machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
			}
			if err := externalWriteSuccess(conn, request["id"], result); err != nil {
				failure <- err
				return
			}
		}
		seen <- requests
	}()
	client, err := cmux.NewClient(cmux.Options{SocketPath: socket})
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := client.Identify(ctx); err != nil {
		t.Fatal(err)
	}
	enabled, disabled := true, false
	if _, err := client.IdentifyWith(ctx, cmux.IdentifyRequest{MachineMetadata: &enabled}); err != nil {
		t.Fatal(err)
	}
	if _, err := client.IdentifyWith(ctx, cmux.IdentifyRequest{MachineMetadata: &disabled}); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-failure:
		t.Fatal(err)
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	case requests := <-seen:
		for index, request := range requests {
			delete(request, "id")
			expected := map[string]any{"cmd": "identify"}
			if index > 0 {
				expected["machine_metadata"] = index == 1
			}
			if !reflect.DeepEqual(request, expected) {
				t.Fatalf("wire request %d = %#v, want %#v", index, request, expected)
			}
		}
	}
}
