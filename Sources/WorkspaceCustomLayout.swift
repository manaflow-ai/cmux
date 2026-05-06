import Bonsplit
import CoreGraphics
import Foundation
import OSLog

nonisolated private let workspaceCustomLayoutLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.cmuxterm.app",
    category: "WorkspaceCustomLayout"
)

func logCustomLayoutMarkdownPathFailure(
    _ failure: CmuxReadableFilePathResolutionFailure,
    context: String
) {
    workspaceCustomLayoutLogger.warning(
        "Custom layout markdown path invalid during \(context, privacy: .public): \(failure.code, privacy: .public)"
    )
}

func absoluteCustomLayoutDirectory(_ directory: String) -> String {
    let expandedDirectory = NSString(string: directory).expandingTildeInPath
    if expandedDirectory.hasPrefix("/") {
        return NSString(string: expandedDirectory).standardizingPath
    }
    let currentDirectory = NSString(string: FileManager.default.currentDirectoryPath)
    return NSString(
        string: currentDirectory.appendingPathComponent(expandedDirectory)
    ).standardizingPath
}

enum WorkspaceCustomLayoutApplyResult {
    case success
    case failure(markdownPath: CmuxReadableFilePathResolutionFailure?)

    var isSuccess: Bool {
        switch self {
        case .success:
            return true
        case .failure:
            return false
        }
    }

    var markdownPathFailure: CmuxReadableFilePathResolutionFailure? {
        switch self {
        case .success:
            return nil
        case .failure(let markdownPath):
            return markdownPath
        }
    }
}

@MainActor
func customLayoutBaseCwdForNewWorkspace(
    tabManager: TabManager,
    requestedCwd: String?
) -> String {
    let inheritedCwd = tabManager.preferredWorkingDirectoryForNewTab(workspace: tabManager.selectedWorkspace)
        ?? FileManager.default.homeDirectoryForCurrentUser.path
    let baseCwd = absoluteCustomLayoutDirectory(inheritedCwd)
    let resolvedCwd = CmuxConfigStore.resolveCwd(
        tabManager.normalizedWorkingDirectory(requestedCwd),
        relativeTo: baseCwd
    )
    return absoluteCustomLayoutDirectory(resolvedCwd)
}

// MARK: - cmux.json custom layout

extension Workspace {

    func applyCustomLayout(_ layout: CmuxLayoutNode, baseCwd: String) -> WorkspaceCustomLayoutApplyResult {
        let resolvedLayout = layout.resolvingMarkdownPaths(relativeTo: baseCwd)
        if let failure = resolvedLayout.failure {
            logCustomLayoutMarkdownPathFailure(failure, context: "layout application")
            return .failure(markdownPath: failure)
        }
        guard let layout = resolvedLayout.layout else { return .failure(markdownPath: nil) }

        return applyResolvedCustomLayout(layout, baseCwd: baseCwd)
    }

    func applyResolvedCustomLayout(
        _ layout: CmuxLayoutNode,
        baseCwd: String
    ) -> WorkspaceCustomLayoutApplyResult {
        guard let rootPaneId = bonsplitController.allPaneIds.first else { return .failure(markdownPath: nil) }

        var leaves: [(paneId: PaneID, surfaces: [CmuxSurfaceDefinition])] = []
        buildCustomLayoutTree(layout, inPane: rootPaneId, leaves: &leaves)

        // First leaf reuses the initial terminal created by addWorkspace;
        // subsequent leaves were created via newTerminalSplit which also seeds
        // a placeholder terminal.
        var focusPanelId: UUID?
        for leaf in leaves {
            guard populateCustomPane(
                leaf.paneId,
                surfaces: leaf.surfaces,
                baseCwd: baseCwd,
                focusPanelId: &focusPanelId
            ) else {
                return .failure(markdownPath: nil)
            }
        }

        let liveRoot = bonsplitController.treeSnapshot()
        applyCustomDividerPositions(configNode: layout, liveNode: liveRoot)

        if let focusPanelId {
            focusPanel(focusPanelId)
        }
        return .success
    }

    private func buildCustomLayoutTree(
        _ node: CmuxLayoutNode,
        inPane paneId: PaneID,
        leaves: inout [(paneId: PaneID, surfaces: [CmuxSurfaceDefinition])]
    ) {
        switch node {
        case .pane(let pane):
            leaves.append((paneId: paneId, surfaces: pane.surfaces))

        case .split(let split):
            guard split.children.count == 2 else {
                workspaceCustomLayoutLogger.warning(
                    "Split node requires exactly 2 children, got \(split.children.count, privacy: .public)"
                )
                leaves.append((paneId: paneId, surfaces: []))
                return
            }

            var anchorPanelId = bonsplitController
                .tabs(inPane: paneId)
                .compactMap { panelIdFromSurfaceId($0.id) }
                .first

            if anchorPanelId == nil {
                anchorPanelId = newTerminalSurface(inPane: paneId, focus: false)?.id
            }

            guard let anchorPanelId,
                  let newSplitPanel = newTerminalSplit(
                      from: anchorPanelId,
                      orientation: split.splitOrientation,
                      insertFirst: false,
                      focus: false
                  ),
                  let secondPaneId = self.paneId(forPanelId: newSplitPanel.id) else {
                leaves.append((paneId: paneId, surfaces: []))
                return
            }

            buildCustomLayoutTree(split.children[0], inPane: paneId, leaves: &leaves)
            buildCustomLayoutTree(split.children[1], inPane: secondPaneId, leaves: &leaves)
        }
    }

    private func populateCustomPane(
        _ paneId: PaneID,
        surfaces: [CmuxSurfaceDefinition],
        baseCwd: String,
        focusPanelId: inout UUID?
    ) -> Bool {
        let existingPanelIds = bonsplitController
            .tabs(inPane: paneId)
            .compactMap { panelIdFromSurfaceId($0.id) }

        guard !surfaces.isEmpty else { return true }

        var nextSurfaceIndex = 0
        if let placeholderPanelId = existingPanelIds.first {
            guard configureExistingSurface(
                panelId: placeholderPanelId,
                inPane: paneId,
                surface: surfaces[0],
                baseCwd: baseCwd,
                focusPanelId: &focusPanelId
            ) else {
                return false
            }
            nextSurfaceIndex = 1
        }

        for surfaceIndex in nextSurfaceIndex..<surfaces.count {
            guard createNewSurface(
                inPane: paneId,
                surface: surfaces[surfaceIndex],
                baseCwd: baseCwd,
                focusPanelId: &focusPanelId
            ) else {
                return false
            }
        }

        return true
    }

    private func configureExistingSurface(
        panelId: UUID,
        inPane paneId: PaneID,
        surface: CmuxSurfaceDefinition,
        baseCwd: String,
        focusPanelId: inout UUID?
    ) -> Bool {
        switch surface.type {
        case .terminal where surface.cwd != nil || surface.env != nil:
            // Placeholder can't change cwd/env; replace it.
            let resolvedCwd = CmuxConfigStore.resolveCwd(surface.cwd, relativeTo: baseCwd)
            guard let panel = newTerminalSurface(
                inPane: paneId,
                focus: false,
                workingDirectory: resolvedCwd,
                startupEnvironment: surface.env ?? [:]
            ) else { return false }
            _ = closePanel(panelId, force: true)
            if let name = surface.name { setPanelCustomTitle(panelId: panel.id, title: name) }
            if surface.focus == true { focusPanelId = panel.id }
            if let command = surface.command { sendInputWhenReady(command + "\n", to: panel) }
            return true

        case .terminal:
            if let name = surface.name { setPanelCustomTitle(panelId: panelId, title: name) }
            if surface.focus == true { focusPanelId = panelId }
            if let command = surface.command, let terminal = terminalPanel(for: panelId) {
                sendInputWhenReady(command + "\n", to: terminal)
            }
            return true

        case .browser:
            let url = surface.url.flatMap { URL(string: $0) }
            guard let panel = newBrowserSurface(
                inPane: paneId,
                url: url,
                focus: false,
                creationPolicy: .restoration
            ) else { return false }
            _ = closePanel(panelId, force: true)
            if let name = surface.name { setPanelCustomTitle(panelId: panel.id, title: name) }
            if surface.focus == true { focusPanelId = panel.id }
            return true

        case .markdown:
            guard let filePath = validatedMarkdownPath(for: surface),
                  let panel = newMarkdownSurface(
                inPane: paneId,
                filePath: filePath,
                focus: false
            ) else { return false }
            _ = closePanel(panelId, force: true)
            if let name = surface.name { setPanelCustomTitle(panelId: panel.id, title: name) }
            if surface.focus == true { focusPanelId = panel.id }
            return true
        }
    }

    private func createNewSurface(
        inPane paneId: PaneID,
        surface: CmuxSurfaceDefinition,
        baseCwd: String,
        focusPanelId: inout UUID?
    ) -> Bool {
        switch surface.type {
        case .terminal:
            let resolvedCwd = CmuxConfigStore.resolveCwd(surface.cwd, relativeTo: baseCwd)
            guard let panel = newTerminalSurface(
                inPane: paneId,
                focus: false,
                workingDirectory: resolvedCwd,
                startupEnvironment: surface.env ?? [:]
            ) else { return false }
            if let name = surface.name { setPanelCustomTitle(panelId: panel.id, title: name) }
            if surface.focus == true { focusPanelId = panel.id }
            if let command = surface.command { sendInputWhenReady(command + "\n", to: panel) }
            return true

        case .browser:
            let url = surface.url.flatMap { URL(string: $0) }
            guard let panel = newBrowserSurface(
                inPane: paneId,
                url: url,
                focus: false,
                creationPolicy: .restoration
            ) else { return false }
            if let name = surface.name { setPanelCustomTitle(panelId: panel.id, title: name) }
            if surface.focus == true { focusPanelId = panel.id }
            return true

        case .markdown:
            guard let filePath = validatedMarkdownPath(for: surface),
                  let panel = newMarkdownSurface(
                inPane: paneId,
                filePath: filePath,
                focus: false
            ) else { return false }
            if let name = surface.name { setPanelCustomTitle(panelId: panel.id, title: name) }
            if surface.focus == true { focusPanelId = panel.id }
            return true
        }
    }

    private func validatedMarkdownPath(for surface: CmuxSurfaceDefinition) -> String? {
        guard let filePath = surface.path,
              !filePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            workspaceCustomLayoutLogger.warning(
                "Markdown surface missing validated path during layout application"
            )
            return nil
        }
        return filePath
    }

    private func applyCustomDividerPositions(
        configNode: CmuxLayoutNode,
        liveNode: ExternalTreeNode
    ) {
        switch (configNode, liveNode) {
        case (.split(let configSplit), .split(let liveSplit)):
            if let splitID = UUID(uuidString: liveSplit.id) {
                _ = bonsplitController.setDividerPosition(
                    CGFloat(configSplit.clampedSplitPosition),
                    forSplit: splitID,
                    fromExternal: true
                )
            }
            if configSplit.children.count == 2 {
                applyCustomDividerPositions(configNode: configSplit.children[0], liveNode: liveSplit.first)
                applyCustomDividerPositions(configNode: configSplit.children[1], liveNode: liveSplit.second)
            }
        default:
            break
        }
    }
}

extension CmuxLayoutNode {
    func resolvingMarkdownPaths(
        relativeTo baseCwd: String
    ) -> (layout: CmuxLayoutNode?, failure: CmuxReadableFilePathResolutionFailure?) {
        switch self {
        case .pane(let pane):
            var surfaces: [CmuxSurfaceDefinition] = []
            surfaces.reserveCapacity(pane.surfaces.count)
            for surface in pane.surfaces {
                let resolved = surface.resolvingMarkdownPath(relativeTo: baseCwd)
                if let failure = resolved.failure {
                    return (nil, failure)
                }
                guard let resolvedSurface = resolved.surface else { return (nil, nil) }
                surfaces.append(resolvedSurface)
            }
            return (.pane(CmuxPaneDefinition(surfaces: surfaces)), nil)

        case .split(let split):
            var children: [CmuxLayoutNode] = []
            children.reserveCapacity(split.children.count)
            for child in split.children {
                let resolved = child.resolvingMarkdownPaths(relativeTo: baseCwd)
                if let failure = resolved.failure {
                    return (nil, failure)
                }
                guard let resolvedChild = resolved.layout else { return (nil, nil) }
                children.append(resolvedChild)
            }
            return (
                .split(CmuxSplitDefinition(direction: split.direction, split: split.split, children: children)),
                nil
            )
        }
    }

    func firstMarkdownPathResolutionFailure(
        relativeTo baseCwd: String
    ) -> CmuxReadableFilePathResolutionFailure? {
        resolvingMarkdownPaths(relativeTo: baseCwd).failure
    }
}

extension CmuxSurfaceDefinition {
    func resolvingMarkdownPath(
        relativeTo baseCwd: String
    ) -> (surface: CmuxSurfaceDefinition?, failure: CmuxReadableFilePathResolutionFailure?) {
        guard type == .markdown else { return (self, nil) }
        let resolved = resolvedMarkdownPath(relativeTo: baseCwd)
        if let failure = resolved.failure {
            return (nil, failure)
        }
        guard let path = resolved.path else { return (nil, nil) }
        var surface = self
        surface.path = path
        return (surface, nil)
    }

    func resolvedMarkdownPath(
        relativeTo baseCwd: String
    ) -> (path: String?, failure: CmuxReadableFilePathResolutionFailure?) {
        guard type == .markdown else { return (nil, nil) }
        return CmuxReadableFilePathResolver.resolve(path ?? "", relativeTo: baseCwd)
    }
}
