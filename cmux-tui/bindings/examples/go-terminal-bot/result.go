package terminalbot

import (
	"fmt"

	cmux "github.com/manaflow-ai/cmux/cmux-tui/bindings/go"
)

// Result contains typed resource IDs and captured terminal state.
type Result struct {
	Workspace    cmux.WorkspaceID
	Screen       cmux.ScreenID
	Pane         cmux.PaneID
	Tab          cmux.TabID
	Terminal     cmux.TerminalID
	Notification cmux.NotificationID

	WorkspaceRevision cmux.Decimal
	TerminalRevision  cmux.Decimal
	ExitCode          int
	ScreenText        string
	HistoryText       string
	Warnings          []string
}

// TaskError reports a completed command with a nonzero exit status.
type TaskError struct {
	ExitCode int
}

func (err *TaskError) Error() string {
	return fmt.Sprintf("terminal task exited with status %d", err.ExitCode)
}
