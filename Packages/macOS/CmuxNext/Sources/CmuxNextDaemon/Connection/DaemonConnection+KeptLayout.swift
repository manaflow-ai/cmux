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

extension DaemonConnection {
    /// Restarts a shell in every kept tab (the next launch after End
    /// Sessions, Keep Layout): each dead tab with a `relaunch` record.
    /// Returns how many restarted. A tab that fails is left dead; the rest
    /// continue.
    @discardableResult
    public func relaunchKeptTabs(fallbackCwd: String?) async throws -> Int {
        let steps = KeptTabRelaunch.steps(tree: try await listWorkspaces(), fallbackCwd: fallbackCwd)
        var relaunched = 0
        for step in steps {
            do {
                try await relaunch(step)
                relaunched += 1
            } catch {
                continue
            }
        }
        return relaunched
    }

    private func relaunch(_ step: KeptTabRelaunch) async throws {
        let created = try await newTab(in: step.pane, options: SpawnOptions(cwd: step.cwd, name: step.name, workspace: step.workspace))
        _ = try await moveTab(created.surface, to: step.pane, index: step.index)
        if step.pinned, identity?.supports(DaemonCapabilities.shared.tabMetadata) == true {
            _ = try await setTabPinned(created.surface, true)
        }
        if let group = step.group {
            _ = try await addTabs([created.surface], toGroup: group)
        }
        try await closeTab(step.deadSurface)
    }
}
