package terminalbot

import (
	"fmt"

	cmux "github.com/manaflow-ai/cmux/cmux-tui/bindings/go"
)

// Result contains exact identifiers and captured terminal state.
type Result struct {
	Workspace cmux.ID
	Screen    cmux.ID
	Pane      cmux.ID
	Surface   cmux.ID

	WorkspaceKey      string
	TerminalID        string
	WorkspaceRevision uint64
	TerminalRevision  uint64
	Notification      cmux.ID

	ExitCode   int
	Output     string
	ScreenText string
	Scrollback string
	EventNames []string
	Reconnects int
	Warnings   []string
}

// TaskError reports a completed command with a nonzero exit status.
type TaskError struct {
	ExitCode int
}

func (err *TaskError) Error() string {
	return fmt.Sprintf("terminal task exited with status %d", err.ExitCode)
}
