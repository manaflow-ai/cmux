package terminalbot_test

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

const (
	fakeMachineID      = "machine_11111111111111111111111111111111"
	fakeSessionID      = "session_22222222222222222222222222222222"
	fakeWorkspaceID    = "ws_33333333333333333333333333333333"
	fakeScreenID       = "screen_44444444444444444444444444444444"
	fakePaneID         = "pane_55555555555555555555555555555555"
	fakeTabID          = "tab_66666666666666666666666666666666"
	fakeTerminalID     = "term_77777777777777777777777777777777"
	fakeNotificationID = "notification_88888888888888888888888888888888"
)

type fakeServer struct {
	t          *testing.T
	socketPath string
	exitCode   int

	mu       sync.Mutex
	requests []map[string]any
	done     chan struct{}
	listener net.Listener
}

func startFakeServer(t *testing.T, exitCode int) *fakeServer {
	t.Helper()
	root, err := os.MkdirTemp("/tmp", "cmux-go-terminal-bot-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(root) })
	socketPath := filepath.Join(root, "resource.sock")
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatal(err)
	}
	server := &fakeServer{
		t: t, socketPath: socketPath, exitCode: exitCode,
		done: make(chan struct{}), listener: listener,
	}
	go server.serve()
	t.Cleanup(server.close)
	return server
}

func (server *fakeServer) close() {
	_ = server.listener.Close()
	<-server.done
}

func (server *fakeServer) serve() {
	defer close(server.done)
	connection, err := server.listener.Accept()
	if err != nil {
		return
	}
	defer connection.Close()
	reader := bufio.NewScanner(connection)
	writer := bufio.NewWriter(connection)
	for reader.Scan() {
		var request map[string]any
		if err := json.Unmarshal(reader.Bytes(), &request); err != nil {
			server.t.Errorf("decode request: %v", err)
			return
		}
		server.mu.Lock()
		server.requests = append(server.requests, request)
		server.mu.Unlock()
		result := server.result(request)
		response := map[string]any{
			"protocol": "cmux.protocol/1",
			"type":     "response",
			"id":       request["id"],
			"ok":       true,
			"result":   result,
		}
		if err := json.NewEncoder(writer).Encode(response); err != nil {
			return
		}
		if err := writer.Flush(); err != nil {
			return
		}
	}
}

func (server *fakeServer) result(request map[string]any) any {
	operation := request["operation"].(string)
	params := request["params"].(map[string]any)
	switch operation {
	case "workspace.create":
		return mutation(map[string]any{
			"kind": "workspace", "workspace_id": fakeWorkspaceID,
		}, "2")
	case "workspace.run":
		return mutation(map[string]any{
			"kind": "terminal", "workspace_id": fakeWorkspaceID,
			"screen_id": fakeScreenID, "pane_id": fakePaneID,
			"tab_id": fakeTabID, "terminal_id": fakeTerminalID,
		}, "3")
	case "terminal.wait":
		pattern := params["pattern"].(string)
		marker := pattern[:len(pattern)-len(":[0-9]+")]
		return map[string]any{"text": fmt.Sprintf("%s:%d\n", marker, server.exitCode)}
	case "terminal.screen.read":
		return map[string]any{"text": "compile finished"}
	case "terminal.history.read":
		return map[string]any{"text": "compile started\ncompile finished"}
	case "notification.create":
		return mutation(map[string]any{
			"id": fakeNotificationID, "session_id": fakeSessionID,
			"title": params["title"], "body": params["body"], "level": params["level"],
			"terminal_id": fakeTerminalID, "created_at_ms": "100", "unread": true,
		}, "4")
	case "workspace.close":
		return mutation(map[string]any{}, "5")
	default:
		server.t.Fatalf("unexpected resource operation %q", operation)
		return nil
	}
}

func mutation(value any, revision string) map[string]any {
	return map[string]any{
		"value": value, "generation": "fake-generation",
		"revision": revision, "replayed": false,
	}
}

func (server *fakeServer) operations() []string {
	server.mu.Lock()
	defer server.mu.Unlock()
	result := make([]string, 0, len(server.requests))
	for _, request := range server.requests {
		result = append(result, request["operation"].(string))
	}
	return result
}

func (server *fakeServer) request(operation string) map[string]any {
	server.mu.Lock()
	defer server.mu.Unlock()
	for _, request := range server.requests {
		if request["operation"] == operation {
			return request
		}
	}
	server.t.Fatalf("missing operation %q", operation)
	return nil
}
