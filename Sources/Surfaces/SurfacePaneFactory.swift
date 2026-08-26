import Bonsplit
import CmuxControlSocket
import Foundation

/// The one place that turns a ``SurfaceDestination`` into a pane. Providers call it to
/// materialize a projection; it maps the destination onto the same `surface.split` /
/// `surface.create` machinery the CLI uses, so a drop from the sidebar lands exactly where a
/// drop of a Vault session or a file would.
///
/// Focus policy (`cmux-socket-policy`): `focus: false` never activates the app, raises a
/// window, or moves selection; the pane is created quietly behind the current focus.
@MainActor
enum SurfacePaneFactory {
    enum FactoryError: Error, LocalizedError {
        case workspaceNotFound(UUID)
        case paneNotFound(String)
        case creationFailed(String)

        var errorDescription: String? {
            switch self {
            case .workspaceNotFound(let id): return "Workspace \(id.uuidString) was not found."
            case .paneNotFound(let id): return "Pane \(id) was not found."
            case .creationFailed(let detail): return "Could not create the pane: \(detail)"
            }
        }
    }

    /// A terminal pane running `initialCommand` (nil → the login shell) at the destination.
    static func makeTerminalPane(
        initialCommand: String?,
        workingDirectory: String?,
        at destination: SurfaceDestination,
        focus: Bool
    ) throws -> (workspaceID: UUID, panelID: UUID) {
        try create(typeRaw: "terminal", url: nil, initialCommand: initialCommand, workingDirectory: workingDirectory, at: destination, focus: focus)
    }

    /// A browser pane loading `url` at the destination.
    static func makeBrowserPane(url: URL, at destination: SurfaceDestination, focus: Bool) throws -> (workspaceID: UUID, panelID: UUID) {
        try create(typeRaw: "browser", url: url.absoluteString, initialCommand: nil, workingDirectory: nil, at: destination, focus: focus)
    }

    /// Selects the workspace and focuses the pane, the way `surface.focus` does — an explicit
    /// focus-intent operation that still never activates the app.
    static func focus(panelID: UUID, in workspaceID: UUID) {
        _ = TerminalController.shared.controlSurfaceFocus(routing: routing(workspaceID: workspaceID), surfaceID: panelID)
    }

    /// Closes a pane (a restored placeholder that a provider replaced).
    static func close(panelID: UUID, in workspaceID: UUID) {
        _ = TerminalController.shared.controlSurfaceClose(routing: routing(workspaceID: workspaceID), surfaceID: panelID, hasSurfaceIDParam: true)
    }

    /// The pane (Bonsplit id) that hosts a panel, for re-projecting in place.
    static func paneID(ofPanel panelID: UUID, in workspaceID: UUID) -> String? {
        guard let workspace = workspace(id: workspaceID) else { return nil }
        return workspace.paneId(forPanelId: panelID)?.id.uuidString
    }

    // MARK: - internals

    private static func routing(workspaceID: UUID) -> ControlRoutingSelectors {
        ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: nil,
            workspaceID: workspaceID,
            surfaceID: nil,
            paneID: nil
        )
    }

    private static func workspace(id: UUID) -> Workspace? {
        AppDelegate.shared?.tabManagerFor(tabId: id)?.tabs.first { $0.id == id }
    }

    /// The surface a split is anchored on: the selected panel of the target pane.
    private static func anchorSurface(paneID: String, in workspace: Workspace) throws -> UUID {
        guard let uuid = UUID(uuidString: paneID) else { throw FactoryError.paneNotFound(paneID) }
        // Resolve the pane the way every socket command does: Bonsplit owns the PaneID
        // values, so look the UUID up among the workspace's live panes instead of
        // synthesizing one.
        guard let located = TerminalController.shared.v2LocatePane(uuid), located.workspace.id == workspace.id,
              let selected = workspace.selectedPanelForPaneDrop(in: located.paneId) else {
            throw FactoryError.paneNotFound(paneID)
        }
        return selected.panelId
    }

    private static func create(
        typeRaw: String,
        url: String?,
        initialCommand: String?,
        workingDirectory: String?,
        at destination: SurfaceDestination,
        focus: Bool
    ) throws -> (workspaceID: UUID, panelID: UUID) {
        let workspaceID = destination.workspaceID
        guard let workspace = workspace(id: workspaceID) else { throw FactoryError.workspaceNotFound(workspaceID) }
        let controller = TerminalController.shared
        let routing = routing(workspaceID: workspaceID)
        switch destination {
        case .tab(_, let paneID, _):
            guard let requestedPane = UUID(uuidString: paneID) else { throw FactoryError.paneNotFound(paneID) }
            return try tab(controller: controller, routing: routing, typeRaw: typeRaw, url: url, initialCommand: initialCommand, workingDirectory: workingDirectory, requestedPane: requestedPane, focus: focus)
        case .workspace(_, .tab):
            return try tab(controller: controller, routing: routing, typeRaw: typeRaw, url: url, initialCommand: initialCommand, workingDirectory: workingDirectory, requestedPane: nil, focus: focus)
        case .split(_, let paneID, let direction):
            let anchor = try anchorSurface(paneID: paneID, in: workspace)
            return try split(controller: controller, routing: routing, typeRaw: typeRaw, url: url, initialCommand: initialCommand, workingDirectory: workingDirectory, direction: direction, anchor: anchor, focus: focus)
        case .workspace(_, .split):
            return try split(controller: controller, routing: routing, typeRaw: typeRaw, url: url, initialCommand: initialCommand, workingDirectory: workingDirectory, direction: .right, anchor: nil, focus: focus)
        }
    }

    private static func tab(
        controller: TerminalController,
        routing: ControlRoutingSelectors,
        typeRaw: String,
        url: String?,
        initialCommand: String?,
        workingDirectory: String?,
        requestedPane: UUID?,
        focus: Bool
    ) throws -> (workspaceID: UUID, panelID: UUID) {
        let resolution = controller.controlSurfaceCreate(
            routing: routing,
            inputs: ControlSurfaceCreateInputs(
                typeRaw: typeRaw,
                providerRaw: nil,
                rendererRaw: nil,
                urlRaw: url,
                workingDirectory: workingDirectory,
                initialCommand: initialCommand,
                tmuxStartCommand: nil,
                remotePTYSessionID: nil,
                remoteContextRaw: nil,
                startupEnvironment: [:],
                // Bonsplit appends a new tab to the pane; no pane drop in the app honors
                // the drop index, so it is not honored here either.
                requestedPaneID: requestedPane,
                requestedFocus: focus
            )
        )
        if case .created(_, let createdWorkspaceID, _, let surfaceID, _) = resolution {
            return (createdWorkspaceID, surfaceID)
        }
        throw FactoryError.creationFailed("\(resolution)")
    }

    private static func split(
        controller: TerminalController,
        routing: ControlRoutingSelectors,
        typeRaw: String,
        url: String?,
        initialCommand: String?,
        workingDirectory: String?,
        direction: SurfaceSplitDirection,
        anchor: UUID?,
        focus: Bool
    ) throws -> (workspaceID: UUID, panelID: UUID) {
        let resolution = controller.controlSurfaceSplit(
            routing: routing,
            inputs: ControlSurfaceSplitInputs(
                directionRaw: direction.rawValue,
                typeRaw: typeRaw,
                urlRaw: url,
                requestedSourceSurfaceID: anchor,
                workingDirectory: workingDirectory,
                initialCommand: initialCommand,
                tmuxStartCommand: nil,
                remotePTYSessionID: nil,
                remoteContextRaw: nil,
                startupEnvironment: [:],
                clientUnsupportedRemoteTmuxOptions: [],
                requestedFocus: focus,
                initialDividerPosition: nil
            )
        )
        if case .created(_, let createdWorkspaceID, _, let surfaceID, _) = resolution {
            return (createdWorkspaceID, surfaceID)
        }
        throw FactoryError.creationFailed("\(resolution)")
    }
}
