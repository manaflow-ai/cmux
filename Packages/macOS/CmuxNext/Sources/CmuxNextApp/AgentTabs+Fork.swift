import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextTabs

/// Where a forked chat opens (``AgentForkDestination``): every fork entry point (the palette's
/// Fork Conversation step, the chat's right-click menu, its shortcut, the chat page's own Fork)
/// ends here once the page has the fork's session. A moved fork never shows in the chat's pane (``AgentForkDestination/Opening/moved``).
extension AgentTabStore {
    /// Opens acpmux session `session` (a fork of chat tab `provisional`, or a started Continue in…)
    /// at `destination`, then gives its composer the keyboard. False when no tab opened.
    func openFork(_ session: String, at destination: AgentForkDestination, beside provisional: String, machine: String? = nil) -> Bool {
        let open: AgentTabOpen = { [weak self] pane, daemon, split in guard let self else { throw CancellationError() }; return try self.open(in: pane, of: daemon, session: session, split: split) }
        let chat = resolvedKey(tabKey(provisional, machine: machine))
        guard let (pane, daemon) = self.pane(for: chat) else { return false }
        let machine = daemon.machineID
        // Made in its split right or below (`conversation-tab-split-v1`; else made in the chat's pane and moved), or a tab.
        let splitFirst = SplitDirection(splitFirst: destination.splitDirection ?? "", served: daemon.supports(DaemonCapability.conversationTabSplit.rawValue)) != nil
        guard destination.opening == .moved || (destination.opening == .split && !splitFirst) else {
            let opened = OpenedFork()
            return openBeside(provisional, machine: machine, split: destination.opening == .split, direction: destination.splitDirection ?? "right",
                              open: open, created: { opened.key = $0 }, finished: { [weak self] _ in opened.key.map { self?.focusForkComposer($0, machine: machine) } })
        }
        let hold = holdOutbound(pane, daemon)
        guard let pending = try? open(pane, daemon, nil), hold?.started(true) != false else { hold?.finish(moved: false); return false }; hold?.made(key: pending.key)
        // task-owner: one tab creation, one move, one focus once it landed (a new workspace: placed in its window, else the chat's showed it)
        Task { [weak self] in
            guard let tab = try? await pending.value(), let self, await TabMirror.reaches(tab.key, in: { [weak self] in self?.locateScoped(AgentTabKey(machine: machine, key: $0)) }) else { hold?.finish(moved: false); return }
            if destination == .workspace || destination == .window { guard await moveToNewWorkspace(tab.key, daemon.machineID, destination == .window) else { hold?.finish(moved: false); return focusForkComposer(tab.key, machine: machine) } } else if let move = destination.moveAction {
                _ = actionRegistry?.perform(move, invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.key), arguments: destination.splitDirection.map { ["direction": .string($0), "keepFocus": .bool(false)] } ?? [:], origin: .user).onMachine(machine))
            } else { placeForkScoped(AgentTabKey(machine: machine, key: tab.key), resolvedKey(chat), { if case let .column(left) = TerminalForkPlacement(destination) { left } else { nil } }()) }
            let moved = await TabMirror.reaches(tab.key, in: { [weak self] in self?.locateScoped(AgentTabKey(machine: machine, key: $0)).flatMap { $0.pane != pane ? $0 : nil } }); hold?.finish(moved: moved)
            focusForkComposer(tab.key, machine: machine)
        }
        return true
    }

    /// The fork's composer takes the keyboard: the person's next words go to the fork, not the chat.
    private func focusForkComposer(_ key: String, machine: String? = nil) {
        let scoped = resolvedKey(tabKey(key, machine: machine)); _ = actionRegistry?.perform("tab.focus", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: scoped.key), origin: .user).onMachine(scoped.machine))
        existingView(scoped.key, machine: scoped.machine)?.focusComposer()
    }
}

@MainActor private final class OpenedFork { var key: String? }
