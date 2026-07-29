package terminalbot

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"

	cmux "github.com/manaflow-ai/cmux/cmux-tui/bindings/go"
)

// Run creates an isolated workspace, runs the exact command, captures terminal
// state, emits a typed notification, and closes the workspace by default.
func (bot *Bot) Run(parent context.Context) (result Result, runErr error) {
	ctx := parent
	cancel := func() {}
	if bot.config.Timeout > 0 {
		ctx, cancel = context.WithTimeout(parent, bot.config.Timeout)
	}
	defer cancel()

	client, err := cmux.NewClient(ctx, cmux.ClientOptions{
		SocketPath: bot.config.SocketPath,
		Session:    bot.config.Session,
		Timeout:    bot.config.IOTimeout,
	})
	if err != nil {
		return result, fmt.Errorf("connect resource client: %w", err)
	}
	defer func() {
		closeCtx, closeCancel := context.WithTimeout(
			context.Background(),
			bot.config.CleanupTimeout,
		)
		defer closeCancel()
		runErr = errors.Join(runErr, client.Close(closeCtx))
	}()

	session := client.
		Machine(cmux.SelectCurrent[cmux.MachineID]()).
		Session(cmux.SelectCurrent[cmux.SessionID]())
	createdWorkspace, err := session.CreateWorkspace(ctx, cmux.WorkspaceCreateOptions{
		Name:           cmux.OptionalString(bot.config.WorkspaceName),
		InitialContent: "empty",
	})
	if err != nil {
		return result, fmt.Errorf("create workspace: %w", err)
	}
	result.Workspace = createdWorkspace.Value.Workspace
	result.WorkspaceRevision = createdWorkspace.Revision
	workspace := session.Workspace(cmux.SelectID(result.Workspace))
	defer func() {
		if bot.config.KeepWorkspace {
			return
		}
		cleanupCtx, cleanupCancel := context.WithTimeout(
			context.Background(),
			bot.config.CleanupTimeout,
		)
		defer cleanupCancel()
		if _, err := workspace.Close(cleanupCtx, cmux.WorkspaceCloseOptions{}); err != nil {
			runErr = errors.Join(runErr, fmt.Errorf("close workspace: %w", err))
		}
	}()

	runOptions := cmux.WorkspaceRunOptions{
		Command: cmux.ExplicitShell("/bin/sh", completionScript(bot.config.Argv, bot.marker)),
		Name:    cmux.OptionalString(bot.config.TerminalName),
	}
	if bot.config.Cwd != "" {
		runOptions.CWD = cmux.OptionalString(bot.config.Cwd)
	}
	createdTerminal, err := workspace.Run(ctx, runOptions)
	if err != nil {
		return result, fmt.Errorf("run terminal command: %w", err)
	}
	path := createdTerminal.Value
	result.Screen = path.Screen
	result.Pane = path.Pane
	result.Tab = path.Tab
	result.Terminal = path.Terminal
	result.TerminalRevision = createdTerminal.Revision
	terminal := workspace.
		Screen(cmux.SelectID(result.Screen)).
		Pane(cmux.SelectID(result.Pane)).
		Tab(cmux.SelectID(result.Tab)).
		Terminal(cmux.SelectID(result.Terminal))

	waitOptions := cmux.TerminalWaitOptions{Pattern: bot.marker + `:[0-9]+`}
	if bot.config.Timeout > 0 {
		milliseconds := cmux.Decimal(bot.config.Timeout.Milliseconds())
		waitOptions.TimeoutMS = &milliseconds
	}
	waited, err := terminal.Wait(ctx, waitOptions)
	if err != nil {
		bot.captureAndNotify(
			terminal,
			session,
			&result,
			"Terminal task interrupted",
			err.Error(),
			"warning",
		)
		return result, fmt.Errorf("wait for completion marker: %w", err)
	}
	waitText, err := documentText(waited, "terminal.wait")
	if err != nil {
		return result, err
	}
	exitCode, err := parseCompletion(waitText, bot.marker)
	if err != nil {
		return result, err
	}
	result.ExitCode = exitCode

	captureCtx, captureCancel := context.WithTimeout(
		context.Background(),
		bot.config.CleanupTimeout,
	)
	defer captureCancel()
	bot.capture(captureCtx, terminal, &result)
	level := "info"
	title := "Terminal task completed"
	if exitCode != 0 {
		level = "error"
		title = "Terminal task failed"
	}
	bot.notify(
		captureCtx,
		session,
		&result,
		title,
		fmt.Sprintf("exit status %d in workspace %s", exitCode, result.Workspace),
		level,
	)
	if bot.config.Output != nil && result.ScreenText != "" {
		if _, err := fmt.Fprintln(bot.config.Output, result.ScreenText); err != nil {
			result.Warnings = append(result.Warnings, "write output: "+err.Error())
		}
	}

	if exitCode != 0 {
		return result, &TaskError{ExitCode: exitCode}
	}
	return result, nil
}

func (bot *Bot) captureAndNotify(
	terminal *cmux.Terminal,
	session *cmux.Session,
	result *Result,
	title string,
	body string,
	level string,
) {
	ctx, cancel := context.WithTimeout(context.Background(), bot.config.CleanupTimeout)
	defer cancel()
	bot.capture(ctx, terminal, result)
	bot.notify(ctx, session, result, title, body, level)
}

func (bot *Bot) capture(ctx context.Context, terminal *cmux.Terminal, result *Result) {
	screen, err := terminal.ReadScreen(ctx, cmux.TerminalScreenReadOptions{})
	if err != nil {
		result.Warnings = append(result.Warnings, "read screen: "+err.Error())
	} else if text, err := documentText(screen, "terminal.screen.read"); err != nil {
		result.Warnings = append(result.Warnings, err.Error())
	} else {
		result.ScreenText = text
	}

	history, err := terminal.ReadHistory(ctx, cmux.TerminalHistoryReadOptions{
		Limit: cmux.OptionalUint32(bot.config.HistoryRows),
	})
	if err != nil {
		result.Warnings = append(result.Warnings, "read history: "+err.Error())
	} else if text, err := documentText(history, "terminal.history.read"); err != nil {
		result.Warnings = append(result.Warnings, err.Error())
	} else {
		result.HistoryText = text
	}
}

func (bot *Bot) notify(
	ctx context.Context,
	session *cmux.Session,
	result *Result,
	title string,
	body string,
	level string,
) {
	created, err := session.CreateNotification(ctx, cmux.NotificationCreateOptions{
		Title:      title,
		Body:       body,
		Level:      cmux.OptionalString(level),
		TerminalID: &result.Terminal,
	})
	if err != nil {
		result.Warnings = append(result.Warnings, "create notification: "+err.Error())
		return
	}
	result.Notification = created.Value.Snapshot().ID
}

func documentText(document cmux.Document, operation string) (string, error) {
	value, ok := document.Fields["text"]
	if !ok {
		return "", fmt.Errorf("%s result omitted text", operation)
	}
	text, ok := value.(string)
	if !ok {
		return "", fmt.Errorf("%s text was not a string", operation)
	}
	return text, nil
}

func parseCompletion(text string, marker string) (int, error) {
	index := strings.LastIndex(text, marker+":")
	if index < 0 {
		return 0, errors.New("terminal.wait result omitted completion marker")
	}
	digits := text[index+len(marker)+1:]
	if newline := strings.IndexAny(digits, "\r\n "); newline >= 0 {
		digits = digits[:newline]
	}
	status, err := strconv.Atoi(digits)
	if err != nil || status < 0 || status > 255 {
		return 0, fmt.Errorf("completion marker had invalid exit status %q", digits)
	}
	return status, nil
}
