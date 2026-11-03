import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemon

/// Where a forked chat opens (``AgentForkDestination``): every fork entry point (the palette's
/// Fork Conversation step, the chat's right-click menu, its shortcut, the chat page's own Fork)
/// ends here once the page has the fork's session.
extension AgentTabStore {
    /// Opens acpmux session `session` (a fork of chat tab `provisional`, or a started Continue in…)
    /// at `destination`, then gives its composer the keyboard. False when no tab opened.
    func openFork(_ session: String, at destination: AgentForkDestination, beside provisional: String) -> Bool {
        let open: (PaneID, DaemonService) throws -> AgentTabPending = { [weak self] pane, daemon in
            guard let self else { throw CancellationError() }
            return try self.open(in: pane, of: daemon, session: session)
        }
        let opened = OpenedFork()
        let move: ActionID? = switch destination {
        case .workspace: "palette.moveTabToNewWorkspace"
        case .window: "tab.moveToNewWindow"
        case .right, .left, .up, .down, .columnRight, .columnLeft, .row, .tab: nil
        }
        // A split: a tab beside the chat, moved to a new split on that side (`tab.moveToNewSplit`).
        // Else a tab after the chat's, and for a workspace or a window then moved there as Move Tab
        // to New Workspace / New Window moves one; for a strip column or row, moved into a new one
        // beside the chat (`DaemonService.placeFork`).
        return openBeside(provisional, split: destination.splitDirection != nil, direction: destination.splitDirection ?? "right",
                          open: open, created: { [weak self] key in
            opened.key = key
            if let move { _ = self?.actionRegistry?.perform(move, invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: key), origin: .user)) }
            if case let .column(left) = TerminalForkPlacement(destination), let self { placeFork(key, resolve(provisional), left) } else if destination == .row, let self { placeFork(key, resolve(provisional), nil) }
        }, finished: { [weak self] _ in
            if let key = opened.key { self?.focusForkComposer(key) }
        })
    }

    /// The fork's composer takes the keyboard: the person's next words go to the fork, not the chat.
    private func focusForkComposer(_ key: String) {
        let tab = resolve(key)
        _ = actionRegistry?.perform("tab.focus", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab), origin: .user))
        existingView(tab)?.focusComposer()
    }
}

/// The fork's tab key, from its creation to the end of its placement.
@MainActor private final class OpenedFork {
    var key: String?
}
