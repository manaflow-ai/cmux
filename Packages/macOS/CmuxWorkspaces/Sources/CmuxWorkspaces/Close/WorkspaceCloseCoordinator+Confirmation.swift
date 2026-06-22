public import Foundation

/// The close-confirmation **decision flow**, moved off the per-window
/// `TabManager` god object. The coordinator owns the re-entrancy session flag,
/// the test-override handler, the anchor-suppression flag read/write, the
/// which-dialog / which-message choice, and the `String(format:)` assembly; the
/// app-side ``CloseConfirming`` witness only supplies the localized string
/// pieces and builds + runs the `NSAlert`. Lifted one-for-one from the legacy
/// `confirmClose` / `confirmAnchorWorkspaceClose` / `confirmPinnedWorkspaceClose`
/// / `beginCloseConfirmationSession` / `endCloseConfirmationSession` bodies.
extension WorkspaceCloseCoordinator {
    /// Whether a close confirmation is currently up (legacy
    /// `TabManager.isCloseConfirmationInFlight`). The shortcut entry points read
    /// this to drop a queued close while a dialog is presented.
    public var isCloseConfirmationInFlight: Bool { closeConfirmationInFlight }

    /// Takes the in-flight confirmation session, returning `false` if one is
    /// already up (legacy `TabManager.beginCloseConfirmationSession()`).
    public func beginCloseConfirmationSession() -> Bool {
        guard !closeConfirmationInFlight else { return false }
        closeConfirmationInFlight = true
        return true
    }

    /// Releases the in-flight confirmation session on the next main-queue turn
    /// (legacy `TabManager.endCloseConfirmationSession()`).
    ///
    /// The async release is load-bearing: ``confirmAnchorWorkspaceClose`` runs
    /// its dialog WITHOUT taking the session so the generic ``confirmClose`` that
    /// follows in the same close path can take it; releasing synchronously here
    /// would clear the flag before that inner `confirmClose` returns. Lifted
    /// verbatim from the legacy `DispatchQueue.main.async` release; the
    /// next-turn hop is the observable contract, not a threading convenience.
    public func endCloseConfirmationSession() {
        DispatchQueue.main.async { [weak self] in
            self?.closeConfirmationInFlight = false
        }
    }

    /// Runs the generic close confirmation, self-gating the in-flight session
    /// and routing through the test handler when set (legacy
    /// `TabManager.confirmClose(title:message:acceptCmdD:)`). Returns whether the
    /// user confirmed.
    public func confirmClose(title: String, message: String, acceptCmdD: Bool) -> Bool {
        guard beginCloseConfirmationSession() else { return false }
        defer { endCloseConfirmationSession() }

        if let confirmCloseHandler {
            return confirmCloseHandler(title, message, acceptCmdD)
        }
        guard let confirming else { return false }
        return confirming.present(
            CloseConfirmationPrompt(
                title: title,
                message: message,
                acceptCmdD: acceptCmdD,
                showsSuppressionCheckbox: false
            )
        ).confirmed
    }

    /// Confirms before closing a workspace that is its group's anchor. Closing
    /// the anchor dissolves the group (other members survive ungrouped).
    /// "Don't ask again" sets the `workspaceGroups.anchorCloseSuppressed` flag.
    /// Lifts the legacy `TabManager.confirmAnchorWorkspaceClose` body one-for-one,
    /// including the which-message choice and the `String.localizedStringWithFormat`
    /// assembly, with the localized format strings supplied by the witness.
    ///
    /// Returns `true` immediately when the dialog is suppressed; returns `false`
    /// (refuse the close) when the witness is unattached.
    public func confirmAnchorWorkspaceClose(groupName: String, otherMemberCount: Int) -> Bool {
        if settings.value(for: settingsCatalog.workspaceGroups.anchorCloseSuppressed) {
            return true
        }
        guard let confirming else { return false }
        // Do NOT acquire beginCloseConfirmationSession here. The standard
        // close confirmation path that runs immediately after (confirmClose())
        // gates itself with the same flag, and endCloseConfirmationSession
        // releases the flag asynchronously on the next main-queue turn — so
        // wrapping this dialog with begin/end would leave the flag set when
        // the inner confirmClose runs, causing it to return false and silently
        // refuse the close even after the user accepted both prompts.
        let title = confirming.closeAnchorTitle
        // Use printf-style format specifiers and String(format:) so the
        // catalog entry can substitute the group name and member count at
        // runtime. Embedding Swift `\(groupName)` interpolation in the
        // catalog `value` would render literal `\(groupName)` on lookup.
        let message: String
        if otherMemberCount == 0 {
            message = String.localizedStringWithFormat(
                confirming.closeAnchorMessageLoneFormat,
                groupName
            )
        } else if otherMemberCount == 1 {
            message = String.localizedStringWithFormat(
                confirming.closeAnchorMessageOneFormat,
                groupName
            )
        } else {
            message = String.localizedStringWithFormat(
                confirming.closeAnchorMessageManyFormat,
                groupName,
                otherMemberCount
            )
        }

        let outcome = confirming.present(
            CloseConfirmationPrompt(
                title: title,
                message: message,
                acceptCmdD: false,
                showsSuppressionCheckbox: true
            )
        )
        guard outcome.confirmed else { return false }
        if outcome.suppressionChecked {
            settings.set(true, for: settingsCatalog.workspaceGroups.anchorCloseSuppressed)
        }
        return true
    }

    /// Confirms before closing a pinned workspace, gated on the close-warning
    /// settings for `source` (legacy `TabManager.confirmPinnedWorkspaceClose`).
    /// Returns `true` (allow close) when no confirmation is required.
    public func confirmPinnedWorkspaceClose(source: CloseConfirmationSource) -> Bool {
        guard shouldConfirmClose(requiresConfirmation: true, source: source) else { return true }
        guard let confirming else { return false }
        return confirmClose(
            title: confirming.closePinnedWorkspaceTitle,
            message: confirming.closePinnedWorkspaceMessage,
            acceptCmdD: model.tabs.count <= 1
        )
    }

    // MARK: - Close-with-confirmation orchestration
    //
    // The single/batch workspace-close decision flow, moved off the per-window
    // `TabManager`. These drive the WHOLE decision over the model + confirmation
    // seam (pinned gate, anchor gate, generic confirm, last-workspace vs
    // non-last routing, batch-abort on cancel) and invert the AppKit
    // window-close / remote-tmux-mark effects through ``WorkspaceCloseHosting``.
    // Lifted one-for-one from the legacy `closeWorkspaceWithConfirmation` /
    // `closeWorkspaceFromCloseTabGesture` / `closeWorkspaceFromTabCloseButton` /
    // `closeWorkspaceIfRunningProcess` / `closeWorkspacesWithConfirmation` /
    // `markRemoteTmuxKillOnWindowCloseIfNeeded` bodies.

    /// Closes `workspace` with the workspace-menu confirmation gating (legacy
    /// `TabManager.closeWorkspaceWithConfirmation(_:)`). Returns whether the
    /// close proceeded.
    @discardableResult
    public func closeWorkspaceWithConfirmation(_ workspace: Tab) -> Bool {
        if workspace.isPinned {
            guard confirmPinnedWorkspaceClose(source: .workspace) else { return false }
            closeWorkspaceIfRunningProcess(workspace, requiresConfirmation: false)
            return true
        }
        closeWorkspaceIfRunningProcess(workspace)
        return true
    }

    /// Closes `workspace` from the Close Tab gesture (legacy
    /// `TabManager.closeWorkspaceFromCloseTabGesture(_:)`).
    @discardableResult
    public func closeWorkspaceFromCloseTabGesture(_ workspace: Tab) -> Bool {
        if workspace.isPinned {
            guard confirmPinnedWorkspaceClose(source: .tabClose) else { return false }
            closeWorkspaceIfRunningProcess(workspace, requiresConfirmation: false)
            return true
        }
        closeWorkspaceIfRunningProcess(workspace, source: .tabClose)
        return true
    }

    /// Closes `workspace` from the tab's X close button (legacy
    /// `TabManager.closeWorkspaceFromTabCloseButton(_:)`).
    @discardableResult
    public func closeWorkspaceFromTabCloseButton(_ workspace: Tab) -> Bool {
        if workspace.isPinned {
            guard confirmPinnedWorkspaceClose(source: .tabCloseButton) else { return false }
            closeWorkspaceIfRunningProcess(workspace, requiresConfirmation: false)
            return true
        }
        closeWorkspaceIfRunningProcess(workspace, source: .tabCloseButton)
        return true
    }

    /// Closes `workspace`, prompting the anchor / generic confirmations as
    /// `source` and `requiresConfirmation` dictate, then routing to the
    /// window-close path for the last workspace or to ``closeWorkspace(_:recordHistory:)``
    /// otherwise (legacy `TabManager.closeWorkspaceIfRunningProcess`).
    public func closeWorkspaceIfRunningProcess(
        _ workspace: Tab,
        requiresConfirmation: Bool = true,
        source: CloseConfirmationSource = .workspace
    ) {
        guard let host else { return }
        // Anchor-close ALWAYS prompts (subject to its own
        // workspaceGroups.anchorCloseSuppressed flag), regardless of
        // requiresConfirmation. Batch-close paths set requiresConfirmation=false
        // after their own generic prompt, but that generic prompt doesn't
        // mention group dissolution — silently ungrouping members during a
        // multi-close would be surprising. The "Don't ask again" toggle on
        // the anchor dialog is the user's opt-out.
        if let groupId = workspace.groupId,
           let group = model.workspaceGroups.first(where: { $0.id == groupId }),
           group.anchorWorkspaceId == workspace.id {
            let otherMemberCount = model.tabs.reduce(0) { partial, tab in
                tab.groupId == groupId && tab.id != workspace.id ? partial + 1 : partial
            }
            if !confirmAnchorWorkspaceClose(groupName: group.name, otherMemberCount: otherMemberCount) {
                return
            }
        }
        let needsCloseConfirmation = host.needsConfirmClose(workspace)
        if requiresConfirmation,
           shouldConfirmClose(requiresConfirmation: needsCloseConfirmation, source: source),
           !confirmClose(
               title: confirming?.closeWorkspaceTitle ?? "",
               message: confirming?.closeWorkspaceMessage ?? "",
               acceptCmdD: model.tabs.count <= 1
           ) {
            return
        }
        if model.tabs.count <= 1 {
            // Last workspace in this window closes via the window-close path, but it
            // is still an explicit TAB/session close: for a remote-tmux mirror, mark
            // the close to KILL the session on commit (synced with tmux), even though
            // it also closes the app window. The marker is consumed on the (non-vetoed)
            // close commit, or cleared if the close is vetoed (single-window quit
            // warning) so a cancelled close never kills. A plain window/quit close
            // never sets it, so it detaches. Non-last workspaces kill via closeWorkspace.
            markRemoteTmuxKillOnWindowCloseIfNeeded(for: [workspace])
            host.closeWindow(containingWorkspaceId: workspace.id)
        } else {
            closeWorkspace(workspace)
        }
    }

    /// Closes the workspaces named by `workspaceIds` with batch confirmation
    /// (legacy `TabManager.closeWorkspacesWithConfirmation(_:allowPinned:)`).
    public func closeWorkspacesWithConfirmation(_ workspaceIds: [UUID], allowPinned: Bool) {
        guard let host else { return }
        let workspaces = orderedClosableWorkspaces(workspaceIds, allowPinned: allowPinned)
        guard !workspaces.isEmpty else { return }
        guard workspaces.count > 1 else {
            closeWorkspaceFromCloseTabGesture(workspaces[0])
            return
        }

        guard let plan = closeWorkspacesPlan(for: workspaces) else { return }
        if shouldConfirmClose(requiresConfirmation: true, source: .tabClose) {
            guard confirmClose(
                title: plan.title,
                message: plan.message,
                acceptCmdD: plan.acceptCmdD
            ) else { return }
        }

        if workspaces.count == model.tabs.count,
           let firstWorkspace = workspaces.first {
            // Closing every tab is still an explicit tab/session close: kill the
            // remote-tmux session(s) on commit, not detach.
            markRemoteTmuxKillOnWindowCloseIfNeeded(for: workspaces)
            // When a real window-close is dispatched (window or AppDelegate
            // present) the window teardown handles the rest; otherwise (headless
            // / no AppDelegate) fall through to the per-workspace loop, matching
            // the legacy behavior.
            if host.closeWindow(containingWorkspaceId: firstWorkspace.id) {
                return
            }
        }

        for workspace in workspaces {
            guard model.tabs.contains(where: { $0.id == workspace.id }) else { continue }
            // Anchor-close confirms inside closeWorkspaceIfRunningProcess.
            // If the user cancels that dialog during a batch, abort the
            // whole batch — otherwise the loop keeps closing later items
            // even though the user said "no" to the dialog that was up.
            if let groupId = workspace.groupId,
               let group = model.workspaceGroups.first(where: { $0.id == groupId }),
               group.anchorWorkspaceId == workspace.id,
               !settings.value(for: settingsCatalog.workspaceGroups.anchorCloseSuppressed) {
                let otherMemberCount = model.tabs.reduce(0) { partial, tab in
                    tab.groupId == groupId && tab.id != workspace.id ? partial + 1 : partial
                }
                if !confirmAnchorWorkspaceClose(groupName: group.name, otherMemberCount: otherMemberCount) {
                    return
                }
                // Anchor confirmed (or suppressed); skip the inner re-prompt
                // by closing without going through closeWorkspaceIfRunningProcess.
                if model.tabs.count <= 1 {
                    // Still a tab/session close → kill the remote session on commit.
                    markRemoteTmuxKillOnWindowCloseIfNeeded(for: [workspace])
                    host.closeWindow(containingWorkspaceId: workspace.id)
                } else {
                    closeWorkspace(workspace)
                }
                continue
            }
            closeWorkspaceIfRunningProcess(workspace, requiresConfirmation: false)
        }
    }

    /// Marks the window's pending close as a tab/session close so a remote-tmux
    /// mirror among `workspaces` is KILLED on commit rather than detached
    /// (legacy `TabManager.markRemoteTmuxKillOnWindowCloseIfNeeded`). The
    /// mirror-membership guard stays here; the window-id lookup and mark invert
    /// through the host.
    private func markRemoteTmuxKillOnWindowCloseIfNeeded(for workspaces: [Tab]) {
        guard let host else { return }
        guard workspaces.contains(where: host.isRemoteTmuxMirror) else { return }
        host.markRemoteTmuxKillOnWindowClose()
    }
}
