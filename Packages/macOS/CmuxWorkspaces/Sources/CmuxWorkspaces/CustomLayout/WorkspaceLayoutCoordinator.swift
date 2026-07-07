public import Foundation
public import Bonsplit

/// Applies a cmux.json `layout` block to a freshly created workspace: it builds
/// the split tree to match the configured nesting, populates each leaf pane with
/// its declared surfaces (terminals, browsers, projects), applies the configured
/// divider positions, and focuses the surface marked `focus: true`.
///
/// These steps are lifted one-for-one from the legacy `Workspace` cmux.json
/// custom-layout extension (`applyCustomLayout`, `buildCustomLayoutTree`,
/// `populateCustomPane`, `configureExistingSurface`, `createNewSurface`,
/// `applyCustomDividerPositions`). The first leaf reuses the initial terminal
/// `addWorkspace` created, and each split's first child reuses the anchor pane
/// while the second child takes the newly split-off pane, exactly as before. All
/// live state — the `BonsplitController` split tree, surface creation, panel
/// titles, focus, divider writes, and the startup-command send — is reached
/// through ``WorkspaceLayoutHosting`` so this type never holds the app-target
/// `Workspace`. The app-target `cmux.json` Codable types stay app-side; the
/// resolved layout arrives as a ``WorkspaceCustomLayoutNode`` value.
@MainActor
public final class WorkspaceLayoutCoordinator {
    private weak var host: (any WorkspaceLayoutHosting)?

    /// Creates the coordinator. Call ``attach(host:)`` before use.
    public init() {}

    /// Attaches the workspace-side host the layout walk drives through.
    public func attach(host: any WorkspaceLayoutHosting) {
        self.host = host
    }

    /// Applies a resolved custom layout to the workspace, lifted from the legacy
    /// `Workspace.applyCustomLayout(_:baseCwd:)`. No-ops when the split controller
    /// has no root pane.
    public func applyCustomLayout(_ layout: WorkspaceCustomLayoutNode, baseCwd: String) {
        guard let host, let rootPaneId = host.layoutRootPaneId() else { return }

        var leaves: [(paneId: PaneID, surfaces: [WorkspaceCustomSurface])] = []
        buildCustomLayoutTree(layout, inPane: rootPaneId, leaves: &leaves)

        // First leaf reuses the initial terminal created by addWorkspace;
        // subsequent leaves were created via newTerminalSplit which also seeds
        // a placeholder terminal.
        var focusPanelId: UUID?
        for leaf in leaves {
            populateCustomPane(leaf.paneId, surfaces: leaf.surfaces, baseCwd: baseCwd, focusPanelId: &focusPanelId)
        }

        let liveRoot = host.layoutTreeSnapshot()
        applyCustomDividerPositions(configNode: layout, liveNode: liveRoot)

        if let focusPanelId {
            host.layoutFocusPanel(focusPanelId)
        }
    }

    private func buildCustomLayoutTree(
        _ node: WorkspaceCustomLayoutNode,
        inPane paneId: PaneID,
        leaves: inout [(paneId: PaneID, surfaces: [WorkspaceCustomSurface])]
    ) {
        guard let host else { return }
        switch node {
        case .pane(let surfaces):
            leaves.append((paneId: paneId, surfaces: surfaces))

        case .split(let orientation, _, let children):
            guard children.count == 2 else {
                #if DEBUG
                NSLog("[CmuxConfig] split node requires exactly 2 children, got %d", children.count)
                #endif
                leaves.append((paneId: paneId, surfaces: []))
                return
            }

            var anchorPanelId = host.layoutPanelIds(inPane: paneId).first

            if anchorPanelId == nil {
                anchorPanelId = host.layoutCreateTerminalSurface(inPane: paneId, focus: false)
            }

            guard let anchorPanelId,
                  let newSplitPanelId = host.layoutCreateTerminalSplit(
                      fromPanelId: anchorPanelId,
                      orientation: orientation,
                      insertFirst: false,
                      focus: false
                  ),
                  let secondPaneId = host.layoutPaneId(forPanelId: newSplitPanelId) else {
                leaves.append((paneId: paneId, surfaces: []))
                return
            }

            buildCustomLayoutTree(children[0], inPane: paneId, leaves: &leaves)
            buildCustomLayoutTree(children[1], inPane: secondPaneId, leaves: &leaves)
        }
    }

    private func populateCustomPane(
        _ paneId: PaneID,
        surfaces: [WorkspaceCustomSurface],
        baseCwd: String,
        focusPanelId: inout UUID?
    ) {
        guard let host else { return }
        let existingPanelIds = host.layoutPanelIds(inPane: paneId)

        guard !surfaces.isEmpty else { return }

        let firstSurface = surfaces[0]
        if let placeholderPanelId = existingPanelIds.first {
            configureExistingSurface(
                panelId: placeholderPanelId,
                inPane: paneId,
                surface: firstSurface,
                baseCwd: baseCwd,
                focusPanelId: &focusPanelId
            )
        }

        for surfaceIndex in 1..<surfaces.count {
            createNewSurface(
                inPane: paneId,
                surface: surfaces[surfaceIndex],
                baseCwd: baseCwd,
                focusPanelId: &focusPanelId
            )
        }
    }

    private func configureExistingSurface(
        panelId: UUID,
        inPane paneId: PaneID,
        surface: WorkspaceCustomSurface,
        baseCwd: String,
        focusPanelId: inout UUID?
    ) {
        guard let host else { return }
        switch surface.kind {
        case .terminal where surface.cwd != nil || surface.env != nil:
            // Placeholder can't change cwd/env — replace it
            let resolvedCwd = host.layoutResolveCwd(surface.cwd, relativeTo: baseCwd)
            if let panel = host.layoutCreateTerminalSurface(
                inPane: paneId,
                focus: false,
                workingDirectory: resolvedCwd,
                startupEnvironment: surface.env ?? [:]
            ) {
                host.layoutClosePanel(panelId, force: true)
                if let name = surface.name { host.layoutSetPanelCustomTitle(panelId: panel, title: name) }
                if surface.focus == true { focusPanelId = panel }
                if let command = surface.command { host.layoutSendStartupCommand(command + "\n", toTerminalPanelId: panel) }
            }

        case .terminal:
            if let name = surface.name { host.layoutSetPanelCustomTitle(panelId: panelId, title: name) }
            if surface.focus == true { focusPanelId = panelId }
            if let command = surface.command {
                host.layoutSendStartupCommand(command + "\n", toTerminalPanelId: panelId)
            }

        case .browser:
            let url = surface.url.flatMap { URL(string: $0) }
            if let panel = host.layoutCreateBrowserSurface(
                inPane: paneId,
                url: url,
                focus: false
            ) {
                host.layoutClosePanel(panelId, force: true)
                if let name = surface.name { host.layoutSetPanelCustomTitle(panelId: panel, title: name) }
                if surface.focus == true { focusPanelId = panel }
            }

        case .project:
            let resolvedProjectPath = host.layoutResolveCwd(surface.url ?? surface.cwd, relativeTo: baseCwd)
            if let panel = host.layoutCreateProjectSurface(
                inPane: paneId,
                projectPath: resolvedProjectPath,
                focus: false
            ) {
                host.layoutClosePanel(panelId, force: true)
                if let name = surface.name { host.layoutSetPanelCustomTitle(panelId: panel, title: name) }
                if surface.focus == true { focusPanelId = panel }
            }
        }
    }

    private func createNewSurface(
        inPane paneId: PaneID,
        surface: WorkspaceCustomSurface,
        baseCwd: String,
        focusPanelId: inout UUID?
    ) {
        guard let host else { return }
        switch surface.kind {
        case .terminal:
            let resolvedCwd = host.layoutResolveCwd(surface.cwd, relativeTo: baseCwd)
            if let panel = host.layoutCreateTerminalSurface(
                inPane: paneId,
                focus: false,
                workingDirectory: resolvedCwd,
                startupEnvironment: surface.env ?? [:]
            ) {
                if let name = surface.name { host.layoutSetPanelCustomTitle(panelId: panel, title: name) }
                if surface.focus == true { focusPanelId = panel }
                if let command = surface.command { host.layoutSendStartupCommand(command + "\n", toTerminalPanelId: panel) }
            }

        case .browser:
            let url = surface.url.flatMap { URL(string: $0) }
            if let panel = host.layoutCreateBrowserSurface(
                inPane: paneId,
                url: url,
                focus: false
            ) {
                if let name = surface.name { host.layoutSetPanelCustomTitle(panelId: panel, title: name) }
                if surface.focus == true { focusPanelId = panel }
            }

        case .project:
            let resolvedProjectPath = host.layoutResolveCwd(surface.url ?? surface.cwd, relativeTo: baseCwd)
            if let panel = host.layoutCreateProjectSurface(
                inPane: paneId,
                projectPath: resolvedProjectPath,
                focus: false
            ) {
                if let name = surface.name { host.layoutSetPanelCustomTitle(panelId: panel, title: name) }
                if surface.focus == true { focusPanelId = panel }
            }
        }
    }

    private func applyCustomDividerPositions(
        configNode: WorkspaceCustomLayoutNode,
        liveNode: ExternalTreeNode
    ) {
        guard let host else { return }
        switch (configNode, liveNode) {
        case (.split(_, let clampedSplitPosition, let children), .split(let liveSplit)):
            if let splitID = UUID(uuidString: liveSplit.id) {
                host.layoutApplySplitDividerPosition(
                    CGFloat(clampedSplitPosition),
                    forSplit: splitID
                )
            }
            if children.count == 2 {
                applyCustomDividerPositions(configNode: children[0], liveNode: liveSplit.first)
                applyCustomDividerPositions(configNode: children[1], liveNode: liveSplit.second)
            }
        default:
            break
        }
    }
}
