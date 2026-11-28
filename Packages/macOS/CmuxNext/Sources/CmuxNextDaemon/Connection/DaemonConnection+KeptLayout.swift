import Foundation

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
                                                 group: tab.tabGroup))
                }
            }
        }
        return steps
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

    /// One kept tab: the new shell opens in the dead tab's pane, takes its
    /// pin first (pinned tabs sort first), moves to the dead tab's current
    /// index (re-read, so an earlier failure cannot shift it), joins its
    /// group, and the dead tab closes.
    private func relaunch(_ step: KeptTabRelaunch) async throws {
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
