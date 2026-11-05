public import CmuxNextDaemon
import CmuxNextBridge
public import Foundation
import os

/// The freeing tier's reads and park on this Mac's daemon (plans/cmux-next/sidebar-recents-and-freeing-DESIGN.md):
/// the facts of a hibernated workspace's terminal tabs, read from the daemon store once per pass, and the park through
/// `park-tabs`. A shown parked tab starts again through `DaemonService.wakeParkedTabs` (a new shell in its folder under
/// the saved screen).
///
/// ```swift
/// let freeing = LocalTerminalFreeing(store: local.store, connection: local.connection, canPark: true)
/// freeing.park(WorkspaceFreeingPlanner().plan(freeing.terminals(in: hibernated), policy: policy, now: Date()).due)
/// ```
@MainActor
public struct LocalTerminalFreeing {
    private let store: DaemonStore
    private let connection: DaemonConnection?
    private let canPark: Bool
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.hibernation")

    /// - Parameters:
    ///   - store: this Mac's daemon store.
    ///   - connection: its connection; nil parks nothing.
    ///   - canPark: the daemon speaks `park-tabs` and kept-layout restart; false frees nothing.
    public init(store: DaemonStore, connection: DaemonConnection?, canPark: Bool) {
        self.store = store
        self.connection = connection
        self.canPark = canPark
    }

    /// This Mac's terminal tabs of `workspaces`, with the facts that keep each shell running.
    public func terminals(in workspaces: Set<String>) -> [WorkspaceFreeingPlanner.Terminal] {
        guard canPark else { return [] }
        return store.workspaces.filter { workspaces.contains($0.id) }.flatMap { workspace in
            let tabs = workspace.screens.flatMap(\.panes).flatMap(\.tabs)
            let facts = WorkspaceActivityFacts(workspace, tabs: tabs)
            return tabs.filter { $0.kind == .pty }.map { tab in
                WorkspaceFreeingPlanner.Terminal(
                    surface: tab.surface.description, workspace: workspace.id, workspaceLastActive: facts.lastActivity,
                    workspaceKept: facts.pinned || facts.running || facts.needsAttention,
                    // A running command clears the prompt: only a shell at its prompt has one.
                    promptSince: tab.commandSinceMs == nil ? date(tab.promptSinceMs) : nil,
                    lastOutput: date(tab.lastOutputMs),
                    // An agent, or a program reporting its status (OSC 7501), keeps the terminal.
                    programReported: !tab.programStatus.isEmpty || tab.agent != nil,
                    local: tab.remote == nil, ended: tab.dead)
            }
        }
    }

    /// Parks `surfaces`: their shells end, their tabs stay and start again when shown.
    public func park(_ surfaces: [String]) {
        let ids = surfaces.compactMap(UInt64.init).map(SurfaceID.init(rawValue:))
        guard canPark, !ids.isEmpty, let connection else { return }
        let logger = logger
        // task-owner: one fire-and-forget park request; the daemon's tree update reports the parked tabs.
        Task {
            do {
                _ = try await connection.request(ParkTabsRequest(surfaces: ids))
            } catch {
                logger.error("idle terminals not freed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

/// A daemon time in Unix milliseconds as a date.
private func date(_ ms: UInt64?) -> Date? { ms.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) } }
