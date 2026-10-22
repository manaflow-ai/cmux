import CmuxNextActions
import CmuxNextDaemon
import CmuxNextSettings
import CmuxNextSidebar

/// A person's close of several selected sidebar rows (Cmd-W, the row menu's Close or the
/// sidebar's Delete on a selection, #23110) as one batch. Leo 2026-10-21: "it's really slow and
/// it's missing a LOT... and it's also 2 lines tall". Each row used to run its own Close
/// Workspace: its own question, titled with its name (a long name wraps to two lines), queued
/// behind the others and not confirmed by Return, then its own turn in the window's lane, which
/// waited for the daemon and the store before the next row's close started. Now every row leaves
/// in one sidebar pass, one question covers them all (`WorkspaceBulkClose.prompt`: "Close N
/// workspaces?"), every close goes out at once in one lane turn, and "Closed N workspaces" with
/// Undo brings them all back (`WorkspaceGroupClose.offerUndo`), as the other bulk closes do.
@MainActor
enum WorkspaceSelectionClose {
    /// Rows whose batch close has started and not ended: a second press sends nothing for them.
    private(set) static var running: Set<String> = []

    /// Closes the workspaces `ids` that window `state` lists.
    static func close(_ ids: [String], in state: WindowState, _ services: AppServices) {
        let windows = services.windows
        let members: [WorkspaceBulkClose.Member] = ids.compactMap { services.machines.workspace(id: $0) }.filter { workspace, _ in
            workspace.key != nil && !HomeRules.isHome(workspace) && !running.contains(workspace.id)
                && !ClosingWorkspaces.shared.ids.contains(workspace.id) && !WorkspaceCloseFlow.running.contains(workspace.id)
        }
        guard !members.isEmpty else { return }
        let closing = members.map(\.0.id), window = state.id, controller = windows.controller(for: window)
        let shownAtPress = controller?.state.workspaceID
        let context = AppActionContext(services: services)
        let undoWindow = WorkspaceBulkClose.survivor(closing: closing, context)
        let incognito = members.contains { windows.isIncognito(workspace: $0.0.id) }
        let seen = Set(DaemonClosedHistory.entries([.workspace], in: services).map(\.item.id))
        let warn = services.settings?.snapshot.warnBeforeClosingTab ?? CmuxConfigSnapshot.closeWarningFallback
        // Every close path tells `willClose` before it closes (WorkspaceClose); in press order.
        let terminals = members.map { WorkspaceClose.closing($0.0, on: $0.1) }
        running.formUnion(closing)
        // In this turn: every row leaves and the selection moves, in one sidebar pass.
        let hidden = InstantClose.begin(closing, in: window, windows: windows)
        let afterPress = controller?.state.workspaceID
        services.registry.track(Task { @MainActor in
            defer { running.subtract(closing) }
            // One question for the whole selection, asked after the rows left (as WorkspaceCloseFlow does).
            if var prompt = await WorkspaceBulkClose.prompt(members, warn: warn, askWithoutUndo: undoWindow == nil, incognito: incognito) {
                prompt.returnConfirms = false
                let confirmed = await withCheckedContinuation { answer in
                    DestructiveConfirmation.present(prompt, in: controller?.window ?? windows.active?.window, settings: services.settings) {
                        answer.resume(returning: $0)
                    }
                }
                guard confirmed else {
                    for id in hidden { ClosingWorkspaces.shared.end(id, refused: false, in: nil) }
                    // The window shows its workspace again unless the person moved on meanwhile.
                    if let shownAtPress, closing.contains(shownAtPress), services.workspace(id: shownAtPress) != nil, let controller,
                       controller.state.workspaceID == afterPress {
                        windows.show(workspaceID: shownAtPress, in: controller.state)
                    }
                    return nil
                }
            }
            // Closed another way while the question was up (the CLI, another window): nothing to send.
            let batch = zip(members, terminals).filter { services.workspace(id: $0.0.0.id) != nil }
            let live = batch.filter { $0.0.1.isLive }, offline = batch.filter { !$0.0.1.isLive }
            // A machine that is not connected (a paused Cloud VM): its closes wait for it outside the
            // window's lane, so later creates and closes never wait for it (WorkspaceCloseFlow).
            for (member, terminals) in offline {
                // task-owner: one close that waits for its machine (WorkspaceCloseFlow's offline close)
                Task { @MainActor in
                    let failure = await send(member, terminals: terminals, waits: true, services)
                    ClosingWorkspaces.shared.end(member.0.id, refused: failure != nil, in: controller?.window)
                }
            }
            return await WorkspaceLanes.shared.run(in: window) {
                // task-owner: one close request each, all sent now; awaited right below.
                let started = live.map { pair in
                    Task { @MainActor in (pair.0, await send(pair.0, terminals: pair.1, waits: false, services)) }
                }
                var results: [(WorkspaceBulkClose.Member, ActionWorkFailure?)] = []
                for task in started { results.append(await task.value) }
                // Closes that went through stay hidden until each store has applied their events.
                var daemons: [ObjectIdentifier: DaemonService] = [:]
                for (member, failure) in results where failure == nil { daemons[ObjectIdentifier(member.1)] = member.1 }
                for daemon in daemons.values {
                    if let connection = daemon.connection { await daemon.store.applied(through: await connection.eventSequence()) }
                }
                let refused = results.filter { $0.1 != nil }
                for (member, failure) in results {
                    // One refusal toast for the batch, not one per row.
                    let says = failure != nil && member.0.id == refused.first?.0.0.id
                    ClosingWorkspaces.shared.end(member.0.id, refused: failure != nil, in: says ? controller?.window : nil)
                }
                let closed = results.filter { $0.1 == nil }.map { $0.0.0.name }
                if closed.count > 1, let undoWindow {
                    WorkspaceGroupClose.offerUndo("workspaces-closed", WorkspaceBulkClose.closedToast(closed.count), groups: [(nil, closed)],
                                                  after: seen, in: undoWindow, services)
                }
                return refused.first?.1
            }.value
        })
    }

    /// One workspace's close on its own machine (`waits`: until that machine connects).
    private static func send(_ member: WorkspaceBulkClose.Member, terminals: [WorkspaceClose.Terminal], waits: Bool,
                             _ services: AppServices) async -> ActionWorkFailure? {
        let (workspace, daemon) = member
        guard let key = workspace.key else { return nil }
        return await daemon.failureOnceConnected("close-workspace", waits: waits, while: { services.machines.daemons.contains { $0 === daemon } }) { connection in
            try await ClosingWorkspaces.shared.refusal()
            try await WorkspaceClose.close(key, terminals: terminals, on: connection)
        }
    }
}
