package terminalbot

import (
	"context"
	"errors"
	"fmt"

	cmux "github.com/manaflow-ai/cmux/cmux-tui/bindings/go"
)

const mutationOrigin = "go-terminal-bot"

type workspaceLease struct {
	id       cmux.ID
	key      string
	revision uint64
}

// Run creates or finds the configured workspace, executes the command, and
// closes the workspace unless KeepWorkspace is set.
func (bot *Bot) Run(parent context.Context) (result Result, runErr error) {
	ctx := parent
	cancel := func() {}
	if bot.config.Timeout > 0 {
		ctx, cancel = context.WithTimeout(parent, bot.config.Timeout)
	}
	defer cancel()

	var lease *workspaceLease
	defer func() {
		if lease == nil || bot.config.KeepWorkspace {
			return
		}
		cleanupCtx, cleanupCancel := context.WithTimeout(
			context.Background(),
			bot.config.CleanupTimeout,
		)
		defer cleanupCancel()
		if err := bot.closeWorkspace(cleanupCtx, lease); err != nil {
			runErr = errors.Join(runErr, err)
		}
	}()

	deltas, err := bot.openDeltaStream(ctx)
	if err != nil {
		return result, err
	}
	defer func() {
		if deltas != nil {
			_ = deltas.Close()
		}
	}()

	tree, err := bot.listWorkspaces(ctx)
	if err != nil {
		return result, err
	}
	// Keep a provisional key lease so cleanup can reconcile an ambiguous
	// create-workspace response after cancellation or transport loss.
	lease = &workspaceLease{key: bot.config.WorkspaceKey}
	ensuredLease, err := bot.ensureWorkspace(ctx, tree)
	if err != nil {
		return result, err
	}
	lease = ensuredLease
	result.Workspace = lease.id
	result.WorkspaceKey = lease.key
	result.WorkspaceRevision = lease.revision

	placement, err := bot.createTerminal(ctx, lease)
	if err != nil {
		return result, err
	}
	result.Screen = placement.Screen
	result.Pane = placement.Pane
	result.Surface = placement.Surface
	result.TerminalID = bot.config.TerminalID
	result.TerminalRevision = placement.TerminalRevision

	bytes, err := bot.openByteStream(ctx, result.Surface)
	if err != nil {
		return result, err
	}
	defer func() {
		if bytes != nil {
			_ = bytes.Close()
		}
	}()

	if err := bot.reportAgent(ctx, result.Surface, cmux.AgentStateWorking); err != nil {
		result.Warnings = append(result.Warnings, err.Error())
	}

	marker := newCompletionMarker(bot.config.MutationID)
	input := marker.command(bot.config.Argv)
	if err := bot.send(ctx, result.Surface, input); err != nil {
		bot.finishInterrupted(&result, err)
		return result, err
	}

	monitor := bot.startMonitor(ctx, result.Surface, deltas, bytes, marker)
	deltas = nil
	bytes = nil
	defer monitor.Close()

	exitCode, err := monitor.waitForMarker(ctx, &result)
	if err != nil {
		bot.finishInterrupted(&result, err)
		return result, fmt.Errorf("monitor terminal task: %w", err)
	}
	result.ExitCode = exitCode

	finishCtx, finishCancel := context.WithTimeout(
		context.Background(),
		bot.config.CleanupTimeout,
	)
	bot.capture(finishCtx, &result)
	state := cmux.AgentStateDone
	if exitCode != 0 {
		state = cmux.AgentStateBlocked
	}
	if err := bot.reportAgent(finishCtx, result.Surface, state); err != nil {
		result.Warnings = append(result.Warnings, err.Error())
	}
	if notification, err := bot.notify(finishCtx, result.Surface, exitCode); err != nil {
		result.Warnings = append(result.Warnings, err.Error())
	} else {
		result.Notification = notification
	}
	if err := bot.send(finishCtx, result.Surface, "\n"); err != nil {
		result.Warnings = append(result.Warnings, err.Error())
	}
	finishCancel()

	exitCtx, exitCancel := context.WithTimeout(context.Background(), bot.config.ExitGrace)
	if err := monitor.waitForExit(exitCtx, &result); err != nil {
		result.Warnings = append(result.Warnings, "wait for terminal exit: "+err.Error())
	}
	exitCancel()

	if exitCode != 0 {
		return result, &TaskError{ExitCode: exitCode}
	}
	return result, nil
}

func (bot *Bot) listWorkspaces(ctx context.Context) (cmux.Tree, error) {
	var tree cmux.Tree
	err := bot.call(ctx, true, "list workspaces", func(client *cmux.Client) error {
		var err error
		tree, err = client.ListWorkspaces(ctx)
		return err
	})
	return tree, err
}

func (bot *Bot) ensureWorkspace(
	ctx context.Context,
	tree cmux.Tree,
) (*workspaceLease, error) {
	for _, workspace := range tree.Workspaces {
		if workspace.Key != nil && *workspace.Key == bot.config.WorkspaceKey {
			return &workspaceLease{
				id:       workspace.ID,
				key:      *workspace.Key,
				revision: uint64Value(tree.WorkspaceRevision),
			}, nil
		}
	}

	key := bot.config.WorkspaceKey
	name := bot.config.WorkspaceName
	origin := mutationOrigin
	mutationID := bot.config.MutationID + "-workspace-create"
	var created cmux.CreateWorkspaceResult
	err := bot.call(ctx, true, "create isolated workspace", func(client *cmux.Client) error {
		var err error
		created, err = client.CreateWorkspace(ctx, cmux.CreateWorkspaceOptions{
			ExpectedGeneration: optionalPresence(tree.Generation),
			ExpectedRevision:   optionalPresence(tree.WorkspaceRevision),
			Key:                cmux.Value(key),
			MutationID:         cmux.Value(mutationID),
			Name:               cmux.Value(name),
			Origin:             cmux.Value(origin),
		})
		return err
	})
	if err != nil {
		return nil, err
	}
	return &workspaceLease{
		id:       created.Workspace,
		key:      created.Key,
		revision: created.WorkspaceRevision,
	}, nil
}

func (bot *Bot) createTerminal(
	ctx context.Context,
	lease *workspaceLease,
) (cmux.CreateTerminalResult, error) {
	var terminals cmux.ListTerminalsResult
	if err := bot.call(ctx, true, "list terminals", func(client *cmux.Client) error {
		var err error
		terminals, err = client.ListTerminals(ctx)
		return err
	}); err != nil {
		return cmux.CreateTerminalResult{}, err
	}

	argv := []string{defaultShell}
	key := lease.key
	name := bot.config.TerminalName
	origin := mutationOrigin
	mutationID := bot.config.MutationID + "-terminal-create"
	terminalID := bot.config.TerminalID
	var created cmux.CreateTerminalResult
	err := bot.call(ctx, true, "create terminal task", func(client *cmux.Client) error {
		var err error
		created, err = client.CreateTerminal(ctx, cmux.CreateTerminalOptions{
			Argv:               cmux.Value(argv),
			Cwd:                optionalString(bot.config.Cwd),
			ExpectedGeneration: cmux.Value(terminals.Generation),
			ExpectedRevision:   cmux.Value(terminals.TerminalRevision),
			Key:                cmux.Value(key),
			MutationID:         cmux.Value(mutationID),
			Name:               cmux.Value(name),
			Origin:             cmux.Value(origin),
			TerminalID:         cmux.Value(terminalID),
		})
		return err
	})
	return created, err
}

func (bot *Bot) send(ctx context.Context, surface cmux.ID, text string) error {
	return bot.call(ctx, false, "send terminal input", func(client *cmux.Client) error {
		return client.Send(ctx, surface, cmux.SendOptions{Text: cmux.Value(text)})
	})
}

func (bot *Bot) reportAgent(
	ctx context.Context,
	surface cmux.ID,
	state cmux.AgentState,
) error {
	session := bot.config.AgentSession
	return bot.call(ctx, true, "report agent state", func(client *cmux.Client) error {
		_, err := client.ReportAgent(
			ctx,
			surface,
			cmux.AgentReportSourceSocket,
			state,
			cmux.ReportAgentOptions{Session: cmux.Value(session)},
		)
		return err
	})
}

func (bot *Bot) notify(
	ctx context.Context,
	surface cmux.ID,
	exitCode int,
) (cmux.ID, error) {
	level := cmux.NotificationLevelInfo
	title := "Terminal task completed"
	body := fmt.Sprintf("exit status %d in workspace %s", exitCode, bot.config.WorkspaceKey)
	if exitCode != 0 {
		level = cmux.NotificationLevelError
		title = "Terminal task failed"
	}
	var notified cmux.NotifyResult
	err := bot.call(ctx, false, "post terminal notification", func(client *cmux.Client) error {
		var err error
		notified, err = client.Notify(ctx, title, body, cmux.NotifyOptions{
			Level:   cmux.Value(level),
			Surface: cmux.Value(surface),
		})
		return err
	})
	return notified.Notification, err
}

func (bot *Bot) finishInterrupted(result *Result, cause error) {
	if result.Surface == 0 {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), bot.config.CleanupTimeout)
	defer cancel()
	bot.capture(ctx, result)
	if err := bot.reportAgent(ctx, result.Surface, cmux.AgentStateBlocked); err != nil {
		result.Warnings = append(result.Warnings, err.Error())
	}
	level := cmux.NotificationLevelWarning
	var notified cmux.NotifyResult
	err := bot.call(ctx, false, "post interruption notification", func(client *cmux.Client) error {
		var err error
		notified, err = client.Notify(
			ctx,
			"Terminal task interrupted",
			cause.Error(),
			cmux.NotifyOptions{
				Level:   cmux.Value(level),
				Surface: cmux.Value(result.Surface),
			},
		)
		return err
	})
	if err != nil {
		result.Warnings = append(result.Warnings, err.Error())
	} else {
		result.Notification = notified.Notification
	}
}

func (bot *Bot) closeWorkspace(ctx context.Context, lease *workspaceLease) error {
	tree, err := bot.listWorkspaces(ctx)
	if err != nil {
		return fmt.Errorf("cleanup workspace snapshot: %w", err)
	}
	found := false
	for _, workspace := range tree.Workspaces {
		if workspace.Key != nil && *workspace.Key == lease.key {
			found = true
			lease.id = workspace.ID
			break
		}
	}
	if !found {
		return nil
	}

	origin := mutationOrigin
	mutationID := bot.config.MutationID + "-workspace-close"
	_, err = func() (cmux.CloseWorkspaceResult, error) {
		var closed cmux.CloseWorkspaceResult
		err := bot.call(ctx, true, "close isolated workspace", func(client *cmux.Client) error {
			var err error
			closed, err = client.CloseWorkspace(ctx, cmux.CloseWorkspaceOptions{
				ExpectedGeneration: optionalPresence(tree.Generation),
				ExpectedRevision:   optionalPresence(tree.WorkspaceRevision),
				Key:                cmux.Value(lease.key),
				MutationID:         cmux.Value(mutationID),
				Origin:             cmux.Value(origin),
				Workspace:          cmux.Value(lease.id),
			})
			return err
		})
		return closed, err
	}()
	return err
}

func optionalString(value string) cmux.Presence[string] {
	if value == "" {
		return cmux.Presence[string]{}
	}
	return cmux.Value(value)
}

func optionalPresence[T any](value *T) cmux.Presence[T] {
	if value == nil {
		return cmux.Presence[T]{}
	}
	return cmux.Value(*value)
}

func uint64Value(value *uint64) uint64 {
	if value == nil {
		return 0
	}
	return *value
}
