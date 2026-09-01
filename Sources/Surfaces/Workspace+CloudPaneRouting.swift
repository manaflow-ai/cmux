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
        // The attach pane shows the TERMINAL, not one of its views, so with
        // multiple views there is no single "anchor's" remote workspace. Prefer
        // the daemon-focused workspace among the anchor's own views (the one the
        // user is most plausibly working in), else its first view in daemon
        // order; a viewless pool terminal passes nil and the provider falls back
        // to the machine's focused workspace.
        let anchorWorkspaces = resource.remoteWorkspaces
        let remoteWorkspaceID = (anchorWorkspaces.first(where: \.focused) ?? anchorWorkspaces.first)?.id
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


/// Writes local rename intents through to the cloud machine a local workspace or pane
/// stands for, so the name persists on that daemon and reaches every attached client.
/// The pane leg lives in `Workspace.setPanelCustomTitle`; this type carries the
/// workspace leg plus the pure target/name rules both legs and the tests share.
enum CloudWorkspaceRenameWriteThrough {
    /// The one remote cmux-tui workspace a local workspace stands for. The persisted
    /// binding wins; otherwise the projected cloud resources decide, but only when
    /// every view agrees on a single remote workspace — a local workspace composing
    /// panes from several remote workspaces (or pool terminals) has no one name to
    /// write, so nothing propagates.
    static func remoteTarget(
        binding: WorkspaceCloudVMBinding?,
        projectedResources: [SurfaceResource]
    ) -> (machine: SurfaceMachineID, remoteWorkspaceID: String)? {
        if let binding, let remote = binding.remoteWorkspaceID, !remote.isEmpty {
            return (.cloud(binding.vmID), remote)
        }
        var seen = Set<String>()
        var found: (SurfaceMachineID, String)?
        for resource in projectedResources where !resource.machine.isLocal {
            for workspace in resource.remoteWorkspaces {
                seen.insert("\(resource.machine.rawValue)\u{1F}\(workspace.id)")
                found = (resource.machine, workspace.id)
            }
        }
        guard seen.count == 1, let found else { return nil }
        return (found.0, found.1)
    }

    /// The daemon-side name for a local title: the "<machine>: " prefix the open path
    /// added is dropped, so renaming "quick-swan: api" writes "api", not the prefix.
    static func remoteName(fromLocalTitle title: String, machine: SurfaceMachineID) -> String? {
        var name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "\(machine.rawValue): "
        if name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return name.isEmpty ? nil : name
    }

    /// Best-effort write-through of a local workspace rename: the daemon persists and
    /// broadcasts the rename, and the next snapshot re-sync is authoritative either way.
    @MainActor
    static func propagate(workspace: Workspace, localTitle: String?) {
        guard let localTitle, !localTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let catalog = SurfaceCatalog.shared
        let projected = catalog.projectionRecords(forWorkspace: workspace.id).compactMap { catalog.resources[$0.resource] }
        guard let target = remoteTarget(binding: workspace.cloudVMBinding, projectedResources: projected),
              let name = remoteName(fromLocalTitle: localTitle, machine: target.machine),
              let provider = catalog.provider(for: target.machine) else { return }
        Task { @MainActor in
            do { try await provider.renameRemoteWorkspace(id: target.remoteWorkspaceID, name: name) }
            catch {
                #if DEBUG
                cmuxDebugLog("cloud.rename.workspace.failed ws=\(workspace.id) error=\(String(describing: error))")
                #endif
            }
        }
    }

    /// Records which machine + remote workspace a just-opened local workspace stands
    /// for, so later local renames write through without guessing from its panes.
    @MainActor
    static func bind(localWorkspaceID: UUID, machine: SurfaceMachineID, remoteWorkspaceID: String?) {
        guard let vmID = machine.cloudMachineID,
              let manager = AppDelegate.shared?.tabManagerFor(tabId: localWorkspaceID),
              let workspace = manager.workspacesById[localWorkspaceID] else { return }
        workspace.cloudVMBinding = WorkspaceCloudVMBinding(
            vmID: vmID,
            isBase: workspace.cloudVMBinding?.isBase ?? false,
            remoteWorkspaceID: remoteWorkspaceID ?? workspace.cloudVMBinding?.remoteWorkspaceID
        )
    }
}
