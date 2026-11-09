public import CmuxNextDaemon
public import Foundation
import os

/// This Mac's daemon as the freeing tier sees it (plans/cmux-next/sidebar-recents-and-freeing-DESIGN.md): the facts
/// of a set of workspaces' terminal tabs, read from the daemon store once per pass, and the park through `park-tabs`.
/// A shown parked tab starts again through `DaemonService.wakeParkedTabs` (a new shell in its folder under the saved
/// screen). The daemon also refuses to park a terminal a client is attached to, or one `set-terminal-keep` keeps.
///
/// ```swift
/// let daemon = DaemonParkableTerminals(store: machines.local.store, connection: { [machines] in machines.local.connection })
/// daemon.park(daemon.terminals(in: hibernated).filter(isIdle).map(\.surface))
/// ```
@MainActor
public final class DaemonParkableTerminals {
    private let store: DaemonStore
    private let connection: @MainActor () -> DaemonConnection?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.hibernation")

    /// - Parameters:
    ///   - store: this Mac's daemon store (its capabilities follow each reconnect).
    ///   - connection: its connection now; nil parks nothing.
    public init(store: DaemonStore, connection: @escaping @MainActor () -> DaemonConnection?) {
        self.store = store
        self.connection = connection
    }

    /// The daemon speaks `park-tabs` and kept-layout restart; else nothing parks and no terminal is listed.
    public var canPark: Bool {
        store.supports(DaemonCapability.tabPark.rawValue) && store.supports(DaemonCapability.tabRestartKeptLayout.rawValue)
    }

    /// The terminal tabs of `workspaces`; empty when the daemon cannot park.
    public func terminals(in workspaces: Set<String>) -> [DaemonTerminalFacts] {
        guard canPark else { return [] }
        return store.workspaces.filter { workspaces.contains($0.id) }.flatMap { workspace in
            let tabs = workspace.screens.flatMap(\.panes).flatMap(\.tabs)
            let facts = WorkspaceActivityFacts(workspace, tabs: tabs)
            let working = StatusMapping.shared.isWorking(tabs: tabs)
            return tabs.filter { $0.kind == .pty }.map { tab in
                DaemonTerminalFacts(
                    surface: tab.surface.description, workspace: workspace.id, workspaceLastActive: facts.lastActivity,
                    // A running command is the planner's per-terminal fact (workspaces.freeing.runningCommands);
                    // agent work and a question for the person keep the workspace.
                    workspaceKept: facts.pinned || working || facts.needsAttention,
                    // A running command clears the prompt: only a shell at its prompt has one.
                    promptSince: tab.commandSinceMs == nil ? date(tab.promptSinceMs) : nil,
                    lastOutput: date(tab.lastOutputMs),
                    programReported: !tab.programStatus.isEmpty || tab.agent != nil,
                    local: tab.remote == nil, ended: tab.dead, runsAgent: tab.agent != nil,
                    agentResumable: resumable(tab), commandSince: date(tab.commandSinceMs))
            }
        }
    }

    /// Parks `surfaces`: their shells end, their tabs stay and start again when shown.
    public func park(_ surfaces: [String]) {
        let ids = surfaces.compactMap(UInt64.init).map(SurfaceID.init(rawValue:))
        guard canPark, !ids.isEmpty, let connection = connection() else { return }
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

/// An agent the person is not waiting on and whose session a respawn resumes (`claude --resume`, `codex resume`).
@MainActor
private func resumable(_ tab: TabModel) -> Bool {
    guard let agent = tab.agent, agent.harnessSessionID != nil, tab.attention == nil else { return false }
    return agent.state == .idle || agent.state == .done
}

/// A daemon time in Unix milliseconds as a date.
private func date(_ ms: UInt64?) -> Date? { ms.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) } }
