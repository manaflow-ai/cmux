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

/// The working directory of each terminal tab when Quit's End Sessions,
/// Keep Layout ended it, by tab resource id. The app writes it before the
/// end and reads it at the next launch (`relaunchKeptTabs`).
public struct KeptLayoutPlan: Codable, Sendable, Equatable {
    public struct Tab: Codable, Sendable, Equatable {
        public var cwd: String?
        public init(cwd: String?) { self.cwd = cwd }
    }

    public var tabs: [String: Tab]

    public init(tabs: [String: Tab]) { self.tabs = tabs }

    /// Every live terminal tab of `tree`, with its current directory.
    public init(tree: DaemonTree) {
        var tabs: [String: Tab] = [:]
        for tab in tree.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs) where tab.kind == .pty && !tab.dead {
            guard let id = tab.tabResourceID?.rawValue else { continue }
            tabs[id] = Tab(cwd: tab.cwd)
        }
        self.tabs = tabs
    }

    /// This plan with `measured` directories (by tab resource id) in place of
    /// the tree's, and `fallback` for a tab with neither.
    public func withDirectories(_ measured: [String: String], fallback: String?) -> KeptLayoutPlan {
        KeptLayoutPlan(tabs: tabs)  // not implemented yet
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

    /// The relaunches `plan` asks for in `tree`: dead terminal tabs whose
    /// tab resource id the plan lists, in tree order.
    public static func steps(tree: DaemonTree, plan: KeptLayoutPlan) -> [KeptTabRelaunch] {
        var steps: [KeptTabRelaunch] = []
        for workspace in tree.workspaces {
            for pane in workspace.screens.flatMap(\.panes) {
                for (index, tab) in pane.tabs.enumerated() where tab.kind == .pty && tab.dead {
                    guard let id = tab.tabResourceID?.rawValue, let kept = plan.tabs[id] else { continue }
                    steps.append(KeptTabRelaunch(workspace: workspace.key, pane: pane.id, deadSurface: tab.surface, index: index,
                                                 cwd: kept.cwd, name: tab.name, pinned: tab.pinned, group: tab.tabGroup))
                }
            }
        }
        return steps
    }
}

extension DaemonConnection {
    /// Restarts a shell in every kept tab `plan` lists (the next launch after
    /// End Sessions, Keep Layout). Returns how many restarted. A tab that
    /// fails is left dead; the rest continue.
    @discardableResult
    public func relaunchKeptTabs(_ plan: KeptLayoutPlan) async throws -> Int {
        let steps = KeptTabRelaunch.steps(tree: try await listWorkspaces(), plan: plan)
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
