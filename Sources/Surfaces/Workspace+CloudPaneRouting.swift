import AppKit
import Bonsplit
import Foundation

/// Cmd+D / Cmd+T from a pane that projects a cloud resource create the new terminal ON
/// that machine — in the same cmux-tui workspace — instead of a local shell. Same rule
/// as the remote tmux mirror: a "split" next to a remote pane means "another terminal
/// where that pane lives". The new terminal is created through the machine's provider
/// (`workspace <ws> run`) and projected back into this workspace at the requested spot,
/// so the sidebar, the socket, and the shortcut agree on what exists.
extension Workspace {
    /// The cloud resource behind a panel, when the panel projects one.
    func cloudProjectedResource(forPanel panelID: UUID) -> SurfaceResource? {
        let catalog = SurfaceCatalog.shared
        guard let projection = catalog.projection(forPanel: panelID),
              projection.workspaceID == id,
              !projection.resource.machine.isLocal else { return nil }
        return catalog.resource(forPanel: panelID)
    }

    /// The cloud resource behind the selected tab of a pane (the Cmd+T anchor).
    func cloudProjectedResource(inPane paneID: PaneID) -> SurfaceResource? {
        guard let selectedTabID = bonsplitController.selectedTab(inPane: paneID)?.id,
              let panelID = panelIdFromSurfaceId(selectedTabID) else { return nil }
        return cloudProjectedResource(forPanel: panelID)
    }

    /// Routes a Cmd+D-style split from a cloud-projected panel to its machine.
    /// Returns false when the source panel is not a cloud projection (create locally).
    func routeCloudPaneTerminalSplit(
        from panelID: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        focus: Bool
    ) -> Bool {
        guard let resource = cloudProjectedResource(forPanel: panelID),
              let paneID = paneId(forPanelId: panelID) else { return false }
        let direction: SurfaceSplitDirection = orientation == .horizontal
            ? (insertFirst ? .left : .right)
            : (insertFirst ? .up : .down)
        return routeCloudPaneTerminalCreate(
            near: resource,
            destination: .split(workspaceID: id, paneID: paneID.id.uuidString, direction: direction),
            focus: focus
        )
    }

    /// Routes a bonsplit UI split (the pane-divider split button) whose source pane
    /// projects a cloud resource: the already-created empty pane receives the machine's
    /// new terminal as its first tab. Returns false when the source is not cloud-anchored.
    func routeCloudPaneUISplit(from sourcePanelID: UUID, into newPane: PaneID) -> Bool {
        guard let resource = cloudProjectedResource(forPanel: sourcePanelID) else { return false }
        return routeCloudPaneTerminalCreate(
            near: resource,
            destination: .tab(workspaceID: id, paneID: newPane.id.uuidString, index: nil),
            focus: true
        )
    }

    /// Routes a Cmd+T-style new tab in a pane whose selected tab projects a cloud
    /// resource to that machine. Returns false when the pane is not cloud-anchored.
    func routeCloudPaneTerminalTab(inPane paneID: PaneID, focus: Bool) -> Bool {
        guard let resource = cloudProjectedResource(inPane: paneID) else { return false }
        return routeCloudPaneTerminalCreate(
            near: resource,
            destination: .tab(workspaceID: id, paneID: paneID.id.uuidString, index: nil),
            focus: focus
        )
    }

    /// Creates a terminal on `resource`'s machine (in the remote workspace of the
    /// anchor's first view, when it has one) and projects it at `destination`.
    /// Optimistic like the cloud tree's "New Terminal Here": the pane appears when the
    /// machine reports the terminal; a failure is announced instead of silently doing
    /// nothing, because the user's gesture otherwise looks dead.
    private func routeCloudPaneTerminalCreate(
        near resource: SurfaceResource,
        destination: SurfaceDestination,
        focus: Bool
    ) -> Bool {
        let catalog = SurfaceCatalog.shared
        guard let provider = catalog.provider(for: resource.machine) else { return false }
        let remoteWorkspaceID = resource.remoteWorkspaces.first?.id
        let machine = resource.machine
        Task { @MainActor in
            do {
                let created = try await provider.createTerminal(
                    command: nil, cwd: nil, name: nil, remoteWorkspaceID: remoteWorkspaceID
                )
                _ = try await catalog.project(created.id, into: destination, focus: focus, reuseExisting: true)
            } catch {
                Self.presentCloudPaneCreationFailure(machine: machine, error: error)
            }
        }
        return true
    }

    @MainActor
    private static func presentCloudPaneCreationFailure(machine: SurfaceMachineID, error: Error) {
        #if DEBUG
        cmuxDebugLog("cloud.pane.createFailed machine=\(machine.rawValue) error=\(String(reflecting: error))")
        #endif
        let alert = NSAlert()
        alert.messageText = String(
            format: String(
                localized: "cloudPane.newTerminalFailed.title",
                defaultValue: "Couldn’t start a terminal on %@"
            ),
            machine.rawValue
        )
        alert.informativeText = CloudMachineLink.errorText(error)
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "cloudPane.newTerminalFailed.ok", defaultValue: "OK"))
        alert.runModal()
    }
}
