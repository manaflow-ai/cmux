import CmuxNextDaemon
import Foundation

/// Builds a `WorkspaceBlueprint` into a new workspace with daemon commands:
/// splits (`split`), scrolling columns (`new-pane-right`), extra screens
/// (`new-screen`), terminal tabs in their directories (`new-tab`), browser
/// tabs (`new-frontend-browser-tab`), then the split ratios. Every new
/// terminal gets the workspace's placement environment. Runs off the main
/// actor; one command at a time, since each needs the pane the previous one
/// made.
struct WorkspaceBlueprintBuilder: Sendable {
    let connection: DaemonConnection
    let key: WorkspaceKey
    /// Browser tabs need `frontend-browser-tabs-v1`; without it they are left out.
    let browsers: Bool
    /// Engine for a page whose engine was not recorded.
    let defaultEngine: BrowserEngine

    /// Fills workspace `key`, whose first pane holds one new terminal (in
    /// the first tab's directory), with `blueprint`.
    func build(_ blueprint: WorkspaceBlueprint) async throws {
        guard let firstScreen = blueprint.screens.first else { return }
        let tree = try await connection.listWorkspaces()
        guard let workspace = tree.workspaces.first(where: { $0.key == key }),
              let firstPane = workspace.screens.first?.panes.first, let initial = firstPane.tabs.first?.surface else { return }
        try await build(firstScreen, pane: firstPane.id, initial: initial)
        for screen in blueprint.screens.dropFirst() {
            let created = try await connection.newScreen(in: workspace.id)
            try await build(screen, pane: try await pane(holding: created.surface), initial: created.surface)
        }
        try await applyRatios(blueprint)
    }

    private func build(_ screen: WorkspaceBlueprint.Screen, pane: PaneID, initial: SurfaceID) async throws {
        guard let first = screen.columns.first else { return }
        try await fill(first.root, pane: pane, initial: initial)
        var previous = pane
        for column in screen.columns.dropFirst() {
            let created = try await connection.newColumn(rightOf: previous, width: column.width, options: options(for: column.root))
            let next = try await self.pane(holding: created.surface)
            try await fill(column.root, pane: next, initial: created.surface)
            previous = next
        }
    }

    /// `pane` holds one new terminal (`initial`) started for `node`'s first tab.
    private func fill(_ node: WorkspaceBlueprint.Node, pane: PaneID, initial: SurfaceID) async throws {
        switch node {
        case .split(let direction, _, let a, let b):
            let created = try await connection.split(pane, direction: direction, options: options(for: b))
            let other = try await self.pane(holding: created.surface)
            try await fill(a, pane: pane, initial: initial)
            try await fill(b, pane: other, initial: created.surface)
        case .pane(let tabs):
            var closeInitial = false
            for (index, tab) in tabs.enumerated() {
                switch tab {
                case .terminal(let cwd):
                    // The pane's first terminal is the one it was made with.
                    if index == 0 { continue }
                    try await connection.newTab(in: pane, options: SpawnOptions(cwd: cwd, workspace: key))
                case .browser(let url, let engine):
                    guard browsers else { continue }
                    try await connection.newFrontendBrowserTab(url: url, engine: engine ?? defaultEngine, in: pane)
                    if index == 0 { closeInitial = true }
                }
            }
            // A pane that starts with a page: its placeholder terminal goes
            // once the page is in, so the pane never empties.
            if closeInitial { try await connection.closeTab(initial) }
        }
    }

    /// New terminal options for a pane whose tabs are `node`'s first leaf.
    private func options(for node: WorkspaceBlueprint.Node) -> SpawnOptions {
        if case .terminal(let cwd)? = node.tabs.first { return SpawnOptions(cwd: cwd, workspace: key) }
        return SpawnOptions(workspace: key)
    }

    private func pane(holding surface: SurfaceID) async throws -> PaneID {
        let tree = try await connection.listWorkspaces()
        let panes = tree.workspaces.first { $0.key == key }?.screens.flatMap(\.panes) ?? []
        guard let pane = panes.first(where: { $0.tabs.contains { $0.surface == surface } }) else {
            throw DaemonError.malformedResponse("pane for surface \(surface) not found")
        }
        return pane.id
    }

    /// Splits are made at the daemon's default ratio; set each to the
    /// blueprint's by walking both trees together (the builder keeps the
    /// original pane as `a` of every split, so the shapes match).
    private func applyRatios(_ blueprint: WorkspaceBlueprint) async throws {
        let tree = try await connection.listWorkspaces()
        guard let workspace = tree.workspaces.first(where: { $0.key == key }) else { return }
        for (screen, built) in zip(blueprint.screens, workspace.screens) {
            let layouts = built.columns.isEmpty ? [built.layout] : built.columns.map(\.layout)
            for (column, layout) in zip(screen.columns, layouts) { try await applyRatios(column.root, layout) }
        }
    }

    private func applyRatios(_ node: WorkspaceBlueprint.Node, _ layout: LayoutNode) async throws {
        guard case .split(_, let ratio, let a, let b) = node, case .split(let id, _, let current, let builtA, let builtB) = layout else { return }
        if let id, abs(current - ratio) > 0.001 { try await connection.setSplitRatio(id, ratio: ratio) }
        try await applyRatios(a, builtA)
        try await applyRatios(b, builtB)
    }
}
