package terminalbot

import (
	"context"
	"errors"
	"fmt"
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
	workspaceCorrelation := bot.correlationKey("workspace.create")
	createdWorkspace, err := bot.createWithRecovery(
		ctx,
		session,
		"workspace.create",
		workspaceCorrelation,
		func(idempotencyKey string) (cmux.MutationResult[cmux.CreatedPath], error) {
			return session.CreateWorkspace(ctx, cmux.WorkspaceCreateOptions{
				MutationOptions: cmux.MutationOptions{
					IdempotencyKey: idempotencyKey,
					CorrelationKey: workspaceCorrelation,
				},
				Name:           cmux.OptionalString(bot.config.WorkspaceName),
				InitialContent: "empty",
			})
		},
	)
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

	runCorrelation := bot.correlationKey("workspace.run")
	createdTerminal, err := bot.createWithRecovery(
		ctx,
		session,
		"workspace.run",
		runCorrelation,
		func(idempotencyKey string) (cmux.MutationResult[cmux.CreatedPath], error) {
			runOptions := cmux.WorkspaceRunOptions{
				MutationOptions: cmux.MutationOptions{
					IdempotencyKey: idempotencyKey,
					CorrelationKey: runCorrelation,
				},
				Command: cmux.Exact(bot.config.Argv...),
				Name:    cmux.OptionalString(bot.config.TerminalName),
			}
			if bot.config.Cwd != "" {
				runOptions.CWD = cmux.OptionalString(bot.config.Cwd)
			}
			return workspace.Run(ctx, runOptions)
		},
	)
	if err != nil {
		return result, fmt.Errorf("run terminal command: %w", err)
	}
	path := createdTerminal.Value
	result.Screen = path.Screen
	result.Pane = path.Pane
	result.Tab = path.Tab
	result.Terminal = path.Terminal
	result.TerminalRevision = createdTerminal.Revision
	terminal := session.Terminal(cmux.SelectID(result.Terminal))

	waitOptions := cmux.TerminalWaitExitOptions{}
	if bot.config.Timeout > 0 {
		milliseconds := cmux.Decimal(bot.config.Timeout.Milliseconds())
		waitOptions.TimeoutMS = &milliseconds
	}
	waited, err := terminal.WaitExit(ctx, waitOptions)
	if err != nil {
		bot.captureAndNotify(
			terminal,
			session,
			&result,
			"Terminal task interrupted",
			err.Error(),
			"warning",
		)
		return result, fmt.Errorf("wait for terminal exit: %w", err)
	}
	exitCode, revision, err := terminalExit(waited)
	if err != nil {
		bot.captureAndNotify(
			terminal,
			session,
			&result,
			"Terminal task ended unexpectedly",
			err.Error(),
			"error",
		)
		return result, err
	}
	result.ExitCode = exitCode
	result.TerminalRevision = revision

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
	} else {
		result.ScreenText = screen.Text
	}

	history, err := terminal.ReadHistory(ctx, cmux.TerminalHistoryReadOptions{
		Limit: cmux.OptionalUint32(bot.config.HistoryRows),
	})
	if err != nil {
		result.Warnings = append(result.Warnings, "read history: "+err.Error())
	} else {
		result.HistoryText = historyText(history)
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

type createCall func(string) (cmux.MutationResult[cmux.CreatedPath], error)

func (bot *Bot) createWithRecovery(
	ctx context.Context,
	session *cmux.Session,
	action string,
	correlationKey string,
	create createCall,
) (cmux.MutationResult[cmux.CreatedPath], error) {
	idempotencyKey := bot.idempotencyKey(action, 0)
	for attempt := 0; attempt < 2; attempt++ {
		created, err := create(idempotencyKey)
		if err == nil {
			return created, nil
		}
		if !creationOutcomeUncertain(err) {
			return cmux.MutationResult[cmux.CreatedPath]{}, err
		}

		resolution, resolveErr := session.ResolveCreation(
			ctx,
			correlationKey,
			cmux.SessionCreationResolveOptions{},
		)
		if resolveErr != nil {
			return cmux.MutationResult[cmux.CreatedPath]{}, errors.Join(err, resolveErr)
		}
		switch resolution.State {
		case cmux.CreationResolutionCreated:
			if resolution.CreatedPath == nil ||
				resolution.Generation == nil ||
				resolution.Revision == nil {
				return cmux.MutationResult[cmux.CreatedPath]{}, fmt.Errorf(
					"%s creation lookup omitted its committed result",
					action,
				)
			}
			return cmux.MutationResult[cmux.CreatedPath]{
				Value:      *resolution.CreatedPath,
				Generation: *resolution.Generation,
				Revision:   *resolution.Revision,
			}, nil
		case cmux.CreationResolutionNotApplied:
			if attempt == 1 {
				break
			}
			if resolution.Recovery == cmux.CreationRetryNewIdempotencyKey {
				idempotencyKey = bot.idempotencyKey(action, attempt+1)
			}
			continue
		default:
			return cmux.MutationResult[cmux.CreatedPath]{}, fmt.Errorf(
				"%s creation lookup returned state=%s recovery=%s",
				action,
				resolution.State,
				resolution.Recovery,
			)
		}
	}
	return cmux.MutationResult[cmux.CreatedPath]{}, fmt.Errorf(
		"%s was not applied after one bounded retry",
		action,
	)
}

func creationOutcomeUncertain(err error) bool {
	var transport *cmux.MutationTransportUncertainError
	if errors.As(err, &transport) {
		return true
	}
	var resource *cmux.ResourceError
	return errors.As(err, &resource) && resource.IsCode("mutation.indeterminate")
}

func (bot *Bot) correlationKey(action string) string {
	return "go-terminal-bot:" + bot.runID + ":" + action
}

func (bot *Bot) idempotencyKey(action string, attempt int) string {
	return fmt.Sprintf(
		"go-terminal-bot:%s:%s:%d",
		bot.runID,
		action,
		attempt,
	)
}

func terminalExit(
	result cmux.TerminalWaitExitResult,
) (int, cmux.Decimal, error) {
	exited, ok := result.(cmux.TerminalWaitExitExited)
	if !ok {
		pending, pendingOK := result.(cmux.TerminalWaitExitPending)
		if pendingOK {
			return 0, pending.Revision, fmt.Errorf(
				"terminal remained %s after its exit wait",
				pending.Lifecycle,
			)
		}
		return 0, 0, fmt.Errorf("terminal exit returned an unknown result")
	}

	switch outcome := exited.Outcome.(type) {
	case cmux.TerminalExitCode:
		return int(outcome.Code), exited.Revision, nil
	case cmux.TerminalExitSignal:
		return 0, exited.Revision, fmt.Errorf(
			"terminal process exited from signal %d (core_dumped=%t)",
			outcome.Signal,
			outcome.CoreDumped,
		)
	case cmux.TerminalExitUnknown:
		return 0, exited.Revision, fmt.Errorf(
			"terminal process exit is unknown: %s",
			outcome.Reason,
		)
	default:
		return 0, exited.Revision, fmt.Errorf(
			"terminal process returned an unknown exit outcome",
		)
	}
}

func historyText(history cmux.TerminalHistoryResult) string {
	lines := make([]string, 0, len(history.Rows))
	for _, row := range history.Rows {
		var line strings.Builder
		for _, run := range row.Runs {
			line.WriteString(run.Text)
		}
		lines = append(lines, line.String())
	}
	return strings.Join(lines, "\n")
}
