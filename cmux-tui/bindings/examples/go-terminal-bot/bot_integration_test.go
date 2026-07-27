package terminalbot_test

import (
	"context"
	"errors"
	"math"
	"strconv"
	"strings"
	"testing"
	"time"

	terminalbot "github.com/manaflow-ai/cmux/cmux-tui/bindings/examples/go-terminal-bot"
	cmux "github.com/manaflow-ai/cmux/cmux-tui/bindings/go"
)

const (
	testWorkspaceKey = "11111111-1111-4111-8111-111111111111"
	testTerminalID   = "22222222-2222-4222-8222-222222222222"
	testMutationID   = "33333333-3333-4333-8333-333333333333"
)

func TestBotCreatesMonitorsReconnectsCapturesAndCleansUp(t *testing.T) {
	server := startFakeServer(t, fakeScenario{
		complete:         true,
		reconnectStreams: true,
		exitCode:         0,
	})
	bot := newTestBot(t, server, 3*time.Second)

	result, err := bot.Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if result.Workspace != fakeWorkspaceID ||
		result.Screen != fakeScreenID ||
		result.Pane != fakePaneID ||
		result.Surface != fakeSurfaceID {
		t.Fatalf("exact IDs were not preserved: %#v", result)
	}
	if result.Notification != fakeNotificationID {
		t.Fatalf("notification = %d, want %d", result.Notification, fakeNotificationID)
	}
	if result.WorkspaceRevision != fakeWorkspaceRevision+1 {
		t.Fatalf(
			"workspace revision = %d, want %d",
			result.WorkspaceRevision,
			fakeWorkspaceRevision+1,
		)
	}
	if result.TerminalRevision != fakeTerminalRevision+1 {
		t.Fatalf(
			"terminal revision = %d, want %d",
			result.TerminalRevision,
			fakeTerminalRevision+1,
		)
	}
	if result.Reconnects < 2 {
		t.Fatalf("reconnects = %d, want at least 2", result.Reconnects)
	}
	if !strings.Contains(result.Output, "CMUX_TERMINAL_BOT_DONE_") {
		t.Fatalf("output does not contain completion marker: %q", result.Output)
	}
	if !strings.Contains(result.Scrollback, "compile started") {
		t.Fatalf("scrollback was not captured: %q", result.Scrollback)
	}
	if !contains(result.EventNames, "surface-output") ||
		!contains(result.EventNames, "output") ||
		(!contains(result.EventNames, "surface-exited") &&
			!contains(result.EventNames, "detached")) {
		t.Fatalf("expected output and lifecycle events, got %v", result.EventNames)
	}
	if len(result.Warnings) != 0 {
		t.Fatalf("unexpected warnings: %v", result.Warnings)
	}

	createdWorkspace := requireRecord(t, server.recordsFor("create-workspace"))
	if createdWorkspace.expectedRevision != strconv.FormatUint(fakeWorkspaceRevision, 10) {
		t.Fatalf("create expected revision = %s", createdWorkspace.expectedRevision)
	}
	createdTerminal := requireRecord(t, server.recordsFor("create-terminal"))
	if createdTerminal.expectedRevision != strconv.FormatUint(fakeTerminalRevision, 10) {
		t.Fatalf("terminal expected revision = %s", createdTerminal.expectedRevision)
	}
	if createdTerminal.expectedGeneration != "generation-exact" {
		t.Fatalf("terminal generation = %q", createdTerminal.expectedGeneration)
	}
	closed := requireRecord(t, server.recordsFor("close-workspace"))
	if closed.workspace != strconv.FormatUint(uint64(fakeWorkspaceID), 10) {
		t.Fatalf("cleanup workspace ID = %s", closed.workspace)
	}
	if closed.expectedRevision != strconv.FormatUint(fakeWorkspaceRevision+1, 10) {
		t.Fatalf("cleanup expected revision = %s", closed.expectedRevision)
	}
	states := server.recordsFor("report-agent")
	if len(states) != 2 || states[0].state != string(cmux.AgentStateWorking) ||
		states[1].state != string(cmux.AgentStateDone) {
		t.Fatalf("agent states = %#v", states)
	}
	notification := requireRecord(t, server.recordsFor("notify"))
	if notification.level != string(cmux.NotificationLevelInfo) {
		t.Fatalf("notification level = %q", notification.level)
	}
	server.assertHealthy(t)
}

func TestBotDiscoversWorkspaceAndReportsNonzeroTask(t *testing.T) {
	server := startFakeServer(t, fakeScenario{
		existingWorkspace: true,
		complete:          true,
		exitCode:          23,
	})
	server.mu.Lock()
	server.workspaceKey = testWorkspaceKey
	server.mu.Unlock()
	bot := newTestBot(t, server, 3*time.Second)

	result, err := bot.Run(context.Background())
	var taskErr *terminalbot.TaskError
	if !errors.As(err, &taskErr) || taskErr.ExitCode != 23 {
		t.Fatalf("got %v, want TaskError(23)", err)
	}
	if result.ExitCode != 23 {
		t.Fatalf("exit code = %d", result.ExitCode)
	}
	if records := server.recordsFor("create-workspace"); len(records) != 0 {
		t.Fatalf("existing workspace was recreated: %#v", records)
	}
	states := server.recordsFor("report-agent")
	if len(states) != 2 || states[1].state != string(cmux.AgentStateBlocked) {
		t.Fatalf("agent states = %#v", states)
	}
	notification := requireRecord(t, server.recordsFor("notify"))
	if notification.level != string(cmux.NotificationLevelError) {
		t.Fatalf("notification level = %q", notification.level)
	}
	requireRecord(t, server.recordsFor("close-workspace"))
	server.assertHealthy(t)
}

func TestBotTimeoutReportsCapturesAndCleansUp(t *testing.T) {
	server := startFakeServer(t, fakeScenario{complete: false})
	bot := newTestBot(t, server, 250*time.Millisecond)

	result, err := bot.Run(context.Background())
	requireErrorIs(t, err, context.DeadlineExceeded)
	if result.ScreenText != "task running" {
		t.Fatalf("screen = %q", result.ScreenText)
	}
	states := server.recordsFor("report-agent")
	if len(states) != 2 || states[1].state != string(cmux.AgentStateBlocked) {
		t.Fatalf("agent states = %#v", states)
	}
	notification := requireRecord(t, server.recordsFor("notify"))
	if notification.level != string(cmux.NotificationLevelWarning) {
		t.Fatalf("notification level = %q", notification.level)
	}
	requireRecord(t, server.recordsFor("close-workspace"))
	server.assertHealthy(t)
}

func TestBotCancellationReportsAndCleansUp(t *testing.T) {
	server := startFakeServer(t, fakeScenario{complete: false})
	bot := newTestBot(t, server, 0)
	ctx, cancel := context.WithCancel(context.Background())
	type outcome struct {
		result terminalbot.Result
		err    error
	}
	finished := make(chan outcome, 1)
	go func() {
		result, err := bot.Run(ctx)
		finished <- outcome{result: result, err: err}
	}()

	select {
	case <-server.started:
		cancel()
	case <-time.After(2 * time.Second):
		t.Fatal("task did not start")
	}
	select {
	case got := <-finished:
		requireErrorIs(t, got.err, context.Canceled)
		if got.result.Notification != fakeNotificationID {
			t.Fatalf("notification = %d", got.result.Notification)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("canceled bot did not stop")
	}
	requireRecord(t, server.recordsFor("close-workspace"))
	server.assertHealthy(t)
}

func TestExactIDsExceedIEEE754IntegerRange(t *testing.T) {
	if uint64(fakeSurfaceID) <= uint64(1)<<53 ||
		fakeWorkspaceRevision <= uint64(1)<<53 ||
		uint64(fakeNotificationID) != math.MaxUint64-36 {
		t.Fatal("fake IDs must exercise exact uint64 values")
	}
}

func newTestBot(
	t *testing.T,
	server *fakeServer,
	timeout time.Duration,
) *terminalbot.Bot {
	t.Helper()
	bot, err := terminalbot.New(terminalbot.Config{
		SocketPath:     server.socketPath,
		WorkspaceKey:   testWorkspaceKey,
		TerminalID:     testTerminalID,
		MutationID:     testMutationID,
		Argv:           []string{"/usr/bin/printf", "hello"},
		Timeout:        timeout,
		IOTimeout:      time.Second,
		CleanupTimeout: time.Second,
		RetryLimit:     3,
		RetryDelay:     time.Millisecond,
		ExitGrace:      time.Second,
		ScrollbackRows: 10,
		MaxOutputBytes: 64 * 1024,
		KeepWorkspace:  false,
	})
	if err != nil {
		t.Fatal(err)
	}
	return bot
}

func contains(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}
