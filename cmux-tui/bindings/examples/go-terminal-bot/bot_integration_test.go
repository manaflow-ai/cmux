package terminalbot_test

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"

	terminalbot "github.com/manaflow-ai/cmux/cmux-tui/bindings/examples/go-terminal-bot"
	cmux "github.com/manaflow-ai/cmux/cmux-tui/bindings/go"
)

func TestBotRunsThroughTypedResourceHandles(t *testing.T) {
	server := startFakeServer(t, 0)
	bot, err := terminalbot.New(terminalbot.Config{
		SocketPath: server.socketPath,
		Argv:       []string{"/usr/bin/printf", "hello"},
		Timeout:    time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	result, err := bot.Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if result.Workspace.String() != fakeWorkspaceID ||
		result.Screen.String() != fakeScreenID ||
		result.Pane.String() != fakePaneID ||
		result.Tab.String() != fakeTabID ||
		result.Terminal.String() != fakeTerminalID {
		t.Fatalf("typed created path was not preserved: %#v", result)
	}
	if result.Notification.String() != fakeNotificationID {
		t.Fatalf("notification = %s", result.Notification)
	}
	if result.ScreenText != "compile finished" ||
		result.HistoryText != "compile started\ncompile finished" {
		t.Fatalf("capture = %#v", result)
	}
	want := []string{
		"workspace.create",
		"workspace.run",
		"terminal.wait_exit",
		"terminal.screen.read",
		"terminal.history.read",
		"notification.create",
		"workspace.close",
	}
	if operations := server.operations(); !reflect.DeepEqual(operations, want) {
		t.Fatalf("operations = %v, want %v", operations, want)
	}
	for _, operation := range server.operations() {
		if operation == "identify" || operation == "list-workspaces" {
			t.Fatalf("legacy operation leaked: %s", operation)
		}
	}
	notification := server.request("notification.create")
	params := notification["params"].(map[string]any)
	if params["terminal_id"] != fakeTerminalID || params["level"] != "info" {
		t.Fatalf("notification params = %#v", params)
	}
	if _, ok := notification["idempotency_key"].(string); !ok {
		t.Fatalf("mutation omitted idempotency key: %#v", notification)
	}
	for _, operation := range []string{"workspace.create", "workspace.run"} {
		request := server.request(operation)
		params := request["params"].(map[string]any)
		correlation, ok := params["correlation_key"].(string)
		if !ok || correlation == "" {
			t.Fatalf("%s omitted correlation_key: %#v", operation, request)
		}
		idempotency, ok := request["idempotency_key"].(string)
		if !ok || idempotency == "" || idempotency == correlation {
			t.Fatalf("%s keys were not distinct: %#v", operation, request)
		}
	}
	run := server.request("workspace.run")["params"].(map[string]any)
	if _, ok := run["shell"]; ok {
		t.Fatalf("workspace.run unexpectedly used a shell: %#v", run)
	}
	if argv, ok := run["argv"].([]any); !ok ||
		!reflect.DeepEqual(argv, []any{"/usr/bin/printf", "hello"}) {
		t.Fatalf("workspace.run argv = %#v", run["argv"])
	}
}

func TestBotReturnsTaskErrorAndErrorNotification(t *testing.T) {
	server := startFakeServer(t, 23)
	bot, err := terminalbot.New(terminalbot.Config{
		SocketPath: server.socketPath,
		Argv:       []string{"/usr/bin/false"},
		Timeout:    time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	result, err := bot.Run(context.Background())
	var taskErr *terminalbot.TaskError
	if !errors.As(err, &taskErr) || taskErr.ExitCode != 23 {
		t.Fatalf("error = %v, want TaskError(23)", err)
	}
	if result.ExitCode != 23 {
		t.Fatalf("exit = %d", result.ExitCode)
	}
	params := server.request("notification.create")["params"].(map[string]any)
	if params["level"] != "error" {
		t.Fatalf("notification level = %v", params["level"])
	}
}

func TestBotRecoversAnExactCreatedPathByCorrelation(t *testing.T) {
	server := startFakeServerWithUncertain(t, 0, "workspace.run")
	bot, err := terminalbot.New(terminalbot.Config{
		SocketPath: server.socketPath,
		Argv:       []string{"/usr/bin/true"},
		Timeout:    time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	result, err := bot.Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if result.Terminal.String() != fakeTerminalID {
		t.Fatalf("recovered terminal = %s", result.Terminal)
	}
	if count := countOperation(server.operations(), "workspace.run"); count != 1 {
		t.Fatalf("workspace.run count = %d", count)
	}
	if count := countOperation(
		server.operations(),
		"session.creation.resolve",
	); count != 1 {
		t.Fatalf("session.creation.resolve count = %d", count)
	}
}

func countOperation(operations []string, target string) int {
	count := 0
	for _, operation := range operations {
		if operation == target {
			count++
		}
	}
	return count
}

func TestPublicRootNoLongerExportsLegacyIDsAtCompileTime(t *testing.T) {
	workspace, err := cmux.ParseWorkspaceID(fakeWorkspaceID)
	if err != nil {
		t.Fatal(err)
	}
	var exact cmux.WorkspaceID = workspace
	if exact.String() != fakeWorkspaceID {
		t.Fatalf("workspace ID = %s", exact)
	}
}
