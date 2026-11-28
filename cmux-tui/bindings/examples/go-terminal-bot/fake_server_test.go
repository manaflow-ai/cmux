package terminalbot_test

import (
	"bufio"
	"encoding/json"
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
	uncertain  string

	mu        sync.Mutex
	requests  []map[string]any
	creations map[string]any
	done      chan struct{}
	listener  net.Listener
}

func startFakeServer(t *testing.T, exitCode int) *fakeServer {
	return startFakeServerWithUncertain(t, exitCode, "")
}

func startFakeServerWithUncertain(
	t *testing.T,
	exitCode int,
	operation string,
) *fakeServer {
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
		t: t, socketPath: socketPath, exitCode: exitCode, uncertain: operation,
		creations: make(map[string]any),
		done:      make(chan struct{}), listener: listener,
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
			"protocol": "cmux.protocol/2",
			"type":     "response",
			"id":       request["id"],
			"ok":       true,
			"result":   result,
		}
		if failure, ok := result.(fakeResourceError); ok {
			response["ok"] = false
			delete(response, "result")
			response["error"] = map[string]any{
				"code": failure.code, "message": failure.message,
				"details": failure.details, "retryable": false,
			}
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
		value := map[string]any{
			"kind": "workspace", "workspace_id": fakeWorkspaceID,
		}
		if server.recordUncertainCreation(request, operation, value, "2") {
			return indeterminate(operation, request)
		}
		return mutation(value, "2")
	case "workspace.run":
		value := map[string]any{
			"kind": "terminal", "workspace_id": fakeWorkspaceID,
			"screen_id": fakeScreenID, "pane_id": fakePaneID,
			"tab_id": fakeTabID, "terminal_id": fakeTerminalID,
		}
		if server.recordUncertainCreation(request, operation, value, "3") {
			return indeterminate(operation, request)
		}
		return mutation(value, "3")
	case "session.creation.resolve":
		correlation := params["correlation_key"].(string)
		server.mu.Lock()
		creation := server.creations[correlation]
		server.mu.Unlock()
		if creation == nil {
			return map[string]any{
				"correlation_key": correlation,
				"state":           "not_applied",
				"recovery":        "retry_new_idempotency_key",
			}
		}
		return creation
	case "terminal.wait_exit":
		return map[string]any{
			"state": "exited", "terminal_id": fakeTerminalID,
			"lifecycle": "exited",
			"outcome": map[string]any{
				"kind": "exit", "code": server.exitCode,
			},
			"exited_at": "100", "revision": "4",
		}
	case "terminal.screen.read":
		return map[string]any{
			"text": "compile finished", "cols": 80, "rows": 24,
			"cursor_row": 0, "cursor_col": 16, "cursor_visible": true,
		}
	case "terminal.history.read":
		return map[string]any{
			"start": "0", "next": "2",
			"rows": []any{
				renderRow(0, "compile started"),
				renderRow(1, "compile finished"),
			},
		}
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

type fakeResourceError struct {
	code    string
	message string
	details map[string]any
}

func indeterminate(operation string, request map[string]any) fakeResourceError {
	return fakeResourceError{
		code:    "mutation.indeterminate",
		message: "the create response was lost",
		details: map[string]any{
			"idempotency_key": request["idempotency_key"],
			"operation":       operation,
			"recovery":        "inspect_state_then_retry_with_new_key",
		},
	}
}

func (server *fakeServer) recordUncertainCreation(
	request map[string]any,
	operation string,
	createdPath map[string]any,
	revision string,
) bool {
	server.mu.Lock()
	defer server.mu.Unlock()
	if server.uncertain != operation {
		return false
	}
	server.uncertain = ""
	correlation := request["params"].(map[string]any)["correlation_key"].(string)
	server.creations[correlation] = map[string]any{
		"correlation_key": correlation,
		"state":           "created",
		"recovery":        "none",
		"operation":       operation,
		"idempotency_key": request["idempotency_key"],
		"created_path":    createdPath,
		"generation":      "fake-generation",
		"revision":        revision,
	}
	return true
}

func renderRow(row int, text string) map[string]any {
	return map[string]any{
		"row": row,
		"runs": []any{
			map[string]any{
				"text": text, "fg": nil, "bg": nil, "attrs": 0,
			},
		},
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
