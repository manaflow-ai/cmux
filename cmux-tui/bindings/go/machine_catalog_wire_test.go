package cmux

import (
	"bufio"
	"context"
	"encoding/json"
	"net"
	"reflect"
	"testing"
	"time"
)

func TestCmuxNextMachineSDKCatalogOptIn(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	clientSide, serverSide := net.Pipe()
	defer serverSide.Close()
	seen := make(chan []map[string]any, 1)
	failure := make(chan error, 1)
	go func() {
		requests := make([]map[string]any, 0, 6)
		decoder := json.NewDecoder(bufio.NewReader(serverSide))
		encoder := json.NewEncoder(serverSide)
		for index := 0; index < 6; index++ {
			var request map[string]any
			if err := decoder.Decode(&request); err != nil {
				failure <- err
				return
			}
			requests = append(requests, request)
			owner := map[string]any{"id": "machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "name": "owner", "origin": "local", "status": "running", "connectable": true, "deleted": false, "recoverable": false}
			if request["params"].(map[string]any)["catalog"] == true {
				owner["platform"] = map[string]any{"os": "linux"}
			}
			var result any = owner
			if index < 3 {
				result = []any{owner}
			}
			if err := encoder.Encode(map[string]any{"protocol": "cmux.protocol/2", "type": "response", "id": request["id"], "ok": true, "result": result}); err != nil {
				failure <- err
				return
			}
		}
		seen <- requests
	}()
	client, err := NewClient(ctx, ClientOptions{SocketPath: "/test/mux.sock", DialContext: func(context.Context, string, string) (net.Conn, error) { return clientSide, nil }})
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close(context.Background())
	if _, err = client.ListMachines(ctx, MachineListOptions{}); err != nil {
		t.Fatal(err)
	}
	if _, err = client.ListMachinesWith(ctx, MachineReadOptions{Catalog: true}); err != nil {
		t.Fatal(err)
	}
	if _, err = client.ListMachinesWith(ctx, MachineReadOptions{}); err != nil {
		t.Fatal(err)
	}
	owner := client.Machine(SelectID(MachineID("machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")))
	if _, err = owner.Refresh(ctx); err != nil {
		t.Fatal(err)
	}
	rich, err := owner.RefreshWith(ctx, MachineReadOptions{Catalog: true})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = owner.RefreshWith(ctx, MachineReadOptions{}); err != nil {
		t.Fatal(err)
	}
	var requests []map[string]any
	select {
	case requests = <-seen:
	case err := <-failure:
		t.Fatal(err)
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	for index, request := range requests {
		expected := map[string]any{}
		if index >= 3 {
			expected["machine"] = "machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
		}
		if index == 1 || index == 4 {
			expected["catalog"] = true
		}
		if !reflect.DeepEqual(request["params"], expected) {
			t.Errorf("wire request %d: got %#v, want %#v", index, request["params"], expected)
		}
		if _, ok := request["idempotency_key"]; ok {
			t.Error("read acquired an idempotency key")
		}
	}
	if rich.Platform == nil || rich.Platform.OS == nil || *rich.Platform.OS != "linux" {
		t.Error("explicit metadata was lost")
	}
}
