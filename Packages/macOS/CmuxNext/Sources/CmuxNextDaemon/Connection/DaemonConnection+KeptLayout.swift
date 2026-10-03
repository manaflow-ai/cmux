import Foundation

/// What `endSessionsAndStop` did.
public struct EndedSessions: Sendable, Equatable {
    public var endedTerminals: UInt64
    /// The placed terminals kept their tabs (`end-terminals-keep-layout-v1`).
    public var keptLayout: Bool

    public init(endedTerminals: UInt64, keptLayout: Bool) {
        self.endedTerminals = endedTerminals
        self.keptLayout = keptLayout
    }
}

/// One kept tab to restart: a new shell opens next to the dead tab in the
/// same pane (so the pane, its split and ratio never change), takes its
/// name, pin and group, and the dead tab closes.
public struct KeptTabRelaunch: Sendable, Equatable {
    public var workspace: WorkspaceKey?
    public var pane: PaneID
    public var deadSurface: SurfaceID
    public var index: Int
    public var cwd: String?
    public var name: String?
    public var pinned: Bool
    public var group: TabGroupID?
    /// `RestartTabRequest.idempotencyKey` of the dead tab.
    public var restartKey: String = ""

    /// The kept tabs of `tree` to restart: dead terminal tabs with the
    /// workspace store's `relaunch` record, in tree order. A record without
    /// a directory restarts in `fallbackCwd`.
    public static func steps(tree: DaemonTree, fallbackCwd: String?) -> [KeptTabRelaunch] {
        var steps: [KeptTabRelaunch] = []
        for workspace in tree.workspaces {
            for pane in workspace.screens.flatMap(\.panes) {
                for (index, tab) in pane.tabs.enumerated() where tab.kind == .pty && tab.dead {
                    guard let relaunch = tab.relaunch else { continue }
                    steps.append(KeptTabRelaunch(workspace: workspace.key, pane: pane.id, deadSurface: tab.surface, index: index,
                                                 cwd: relaunch.cwd ?? fallbackCwd, name: tab.name, pinned: tab.pinned,
                                                 group: tab.tabGroup,
                                                 restartKey: RestartTabRequest.idempotencyKey(tab: tab)))
                }
            }
        }
        return steps
    }
}

extension KeptTabRelaunch {
    /// `restart-tab` on a daemon that serves `tab-restart-v1`; false when it
    /// does not (the caller relaunches by new tab, move and close).
    func restartInPlace(on connection: DaemonConnection) async throws -> Bool {
        guard await connection.identity?.supports(DaemonCapabilities.shared.tabRestart) == true else { return false }
        try await RestartTabRequest.send(deadSurface, on: connection, idempotencyKey: restartKey, fallbackCwd: cwd)
        return true
    }
}

/// What `relaunchKeptTabs` did.
public struct KeptTabsRelaunched: Sendable, Equatable {
    public var relaunched: Int
    /// One line per kept tab that failed (it stays dead).
    public var failures: [String]
}

extension DaemonConnection {
    /// Restarts a shell in every kept tab (the next launch after End
    /// Sessions, Keep Layout): each dead tab with a `relaunch` record. A tab
    /// that fails stays dead and is reported; the rest continue.
    @discardableResult
    public func relaunchKeptTabs(fallbackCwd: String?) async throws -> KeptTabsRelaunched {
        let steps = KeptTabRelaunch.steps(tree: try await listWorkspaces(), fallbackCwd: fallbackCwd)
        var result = KeptTabsRelaunched(relaunched: 0, failures: [])
        for step in steps {
            do {
                try await relaunch(step)
                result.relaunched += 1
            } catch {
                result.failures.append("surface \(step.deadSurface.rawValue): \(error)")
            }
        }
        return result
    }

    /// One kept tab: `restart-tab` in place, else a new shell in its pane takes its pin, index (re-read, so an
    /// earlier failure cannot shift it) and group, and the dead tab closes.
    private func relaunch(_ step: KeptTabRelaunch) async throws {
        if try await step.restartInPlace(on: self) { return }
        let created = try await newTab(in: step.pane, options: SpawnOptions(cwd: step.cwd, name: step.name, workspace: step.workspace))
        if step.pinned, identity?.supports(DaemonCapabilities.shared.tabMetadata) == true {
            _ = try await setTabPinned(created.surface, true)
        }
        let panes = try await listWorkspaces().workspaces.flatMap(\.screens).flatMap(\.panes)
        if let pane = panes.first(where: { $0.tabs.contains { $0.surface == step.deadSurface } }),
           let index = pane.tabs.firstIndex(where: { $0.surface == step.deadSurface }) {
            _ = try await moveTab(created.surface, to: pane.id, index: index)
        }
        if let group = step.group {
            _ = try await addTabs([created.surface], toGroup: group)
        }
        try await closeTab(step.deadSurface)
    }
}
