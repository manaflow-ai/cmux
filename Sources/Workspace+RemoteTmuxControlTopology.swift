import Bonsplit
import CmuxWorkspaces
import Foundation

@MainActor
extension Workspace {
    typealias ControlSurfaceProjection = (
        surfaceID: UUID,
        paneID: UUID?,
        panel: any Panel
    )
    enum RemoteTmuxControlSurfaceTarget {
        case notRemote
        case unresolvedMirror
        case pane(RemoteTmuxControlPaneLocation)
    }

    func remoteTmuxControlPane(paneID: UUID) -> RemoteTmuxControlPaneLocation? {
        if let sessionMirror = remoteTmuxSessionMirror {
            return sessionMirror.controlPaneLocation(paneID: paneID)
        }
        for (containerPanelID, mirror) in remoteTmuxWindowMirrors {
            if let pane = mirror.controlPane(paneID: paneID) {
                return RemoteTmuxControlPaneLocation(
                    containerPanelID: containerPanelID,
                    owner: mirror,
                    windowMirror: mirror,
                    pane: pane
                )
            }
        }
        return nil
    }

    func remoteTmuxControlPane(surfaceID: UUID) -> RemoteTmuxControlPaneLocation? {
        if let sessionMirror = remoteTmuxSessionMirror {
            return sessionMirror.controlPaneLocation(surfaceID: surfaceID)
        }
        for (containerPanelID, mirror) in remoteTmuxWindowMirrors {
            if let pane = mirror.controlPane(surfaceID: surfaceID) {
                return RemoteTmuxControlPaneLocation(
                    containerPanelID: containerPanelID,
                    owner: mirror,
                    windowMirror: mirror,
                    pane: pane
                )
            }
        }
        return nil
    }

    func remoteTmuxControlPanes(
        containerPanelID: UUID
    ) -> [RemoteTmuxControlPaneLocation] {
        if let sessionMirror = remoteTmuxSessionMirror {
            return sessionMirror.controlPaneLocations(containerPanelID: containerPanelID)
        }
        guard let mirror = remoteTmuxWindowMirrors[containerPanelID] else { return [] }
        return mirror.controlPanes().map {
            RemoteTmuxControlPaneLocation(
                containerPanelID: containerPanelID,
                owner: mirror,
                windowMirror: mirror,
                pane: $0
            )
        }
    }

    func isRemoteTmuxControlContainer(_ panelID: UUID) -> Bool {
        remoteTmuxSessionMirror?.windowId(forPanel: panelID) != nil
            || remoteTmuxWindowMirrors[panelID] != nil
    }

    func activeRemoteTmuxControlPane(
        containerPanelID: UUID
    ) -> RemoteTmuxControlPaneLocation? {
        if let sessionMirror = remoteTmuxSessionMirror {
            return sessionMirror.activeControlPaneLocation(containerPanelID: containerPanelID)
        }
        guard let mirror = remoteTmuxWindowMirrors[containerPanelID],
              let pane = mirror.activeControlPane() else {
            return nil
        }
        return RemoteTmuxControlPaneLocation(
            containerPanelID: containerPanelID,
            owner: mirror,
            windowMirror: mirror,
            pane: pane
        )
    }

    /// Resolves an active nested input surface without constructing the
    /// title-bearing control mutation DTO used by socket operations.
    func activeRemoteTmuxControlSurfaceProjection(
        containerPanelID: UUID
    ) -> ControlSurfaceProjection? {
        if let sessionMirror = remoteTmuxSessionMirror {
            guard let projection = sessionMirror.activeControlSurfaceProjection(
                containerPanelID: containerPanelID
            ) else { return nil }
            return (projection.surfaceID, projection.paneID, projection.panel)
        }
        guard let mirror = remoteTmuxWindowMirrors[containerPanelID],
              let projection = mirror.activeControlSurfaceProjection() else { return nil }
        return (projection.surfaceID, projection.paneID, projection.panel)
    }

    /// Resolves a control-plane surface identity to its tab mutation owner and
    /// exposed pane. Mirror topology remains authoritative: projected panes
    /// resolve to their window container, while an unresolved hidden container
    /// fails closed instead of falling through to its local wrapper panel.
    func controlTabTarget(for surfaceID: UUID) -> (panelID: UUID, paneID: UUID?)? {
        switch remoteTmuxControlSurfaceTarget(surfaceID: surfaceID) {
        case .pane(let location):
            return (location.containerPanelID, location.pane.paneID.id)
        case .unresolvedMirror:
            return nil
        case .notRemote:
            guard panels[surfaceID] != nil else { return nil }
            return (surfaceID, paneId(forPanelId: surfaceID)?.id)
        }
    }

    /// Resolves every mirror-owned surface identity without conflating an
    /// unresolved mirror with an ordinary workspace surface.
    func remoteTmuxControlSurfaceTarget(surfaceID: UUID) -> RemoteTmuxControlSurfaceTarget {
        if let location = remoteTmuxControlPane(surfaceID: surfaceID) {
            return .pane(location)
        }
        guard isRemoteTmuxControlContainer(surfaceID) else {
            return .notRemote
        }
        // The wrapper UUID identifies the mirror container, not a tmux pane.
        // Never alias it to the mutable active pane: callers may cache handles,
        // and a later focus publication would silently retarget that handle.
        return .unresolvedMirror
    }

    /// Maps a control-plane surface identity to the workspace-owned tab that
    /// participates in reorder. Projected tmux pane surfaces reorder their
    /// window container; hidden mirror wrappers remain unresolved.
    func controlReorderContainerPanelID(for surfaceID: UUID) -> UUID? {
        switch remoteTmuxControlSurfaceTarget(surfaceID: surfaceID) {
        case .pane(let location):
            return location.containerPanelID
        case .unresolvedMirror:
            return nil
        case .notRemote:
            return panels[surfaceID] == nil ? nil : surfaceID
        }
    }

    /// Intercepts focus requests the remote tmux layer owns. Focus activation
    /// is dropped while mirror mutations suppress it, and a mirror-projected
    /// pane surface — which is not a Bonsplit tab, so the ordinary focus path
    /// cannot resolve it — routes through the pane's sole mutation owner
    /// (select-pane on the remote) before focusing the mirror's container
    /// panel, mirroring `focusRemoteTmuxControlPane`. Every tmux pane surface is
    /// mirror-owned, including a one-pane window; only the workspace-owned
    /// container identity stays on the ordinary focus path, which terminates
    /// container recursion. Returns true when the request was consumed.
    func remoteTmuxMirrorInterceptsFocusPanel(
        _ panelId: UUID,
        previousHostedView: GhosttySurfaceScrollView?,
        trigger: FocusPanelTrigger,
        focusIntent: PanelFocusIntent?
    ) -> Bool {
        if remoteTmuxMirrorMutations.suppressesFocusActivation { return true }
        guard let location = remoteTmuxControlPane(surfaceID: panelId),
              location.containerPanelID != panelId else { return false }
        _ = location.controlFocus()
        focusPanel(
            location.containerPanelID,
            previousHostedView: previousHostedView,
            trigger: trigger,
            focusIntent: focusIntent
        )
        return true
    }

    /// Canonicalizes an explicit control-plane terminal target. Hidden mirror
    /// containers fail closed instead of exposing their stale wrapper panel.
    func controlSurfaceTarget(for surfaceID: UUID) -> ControlSurfaceProjection? {
        switch remoteTmuxControlSurfaceTarget(surfaceID: surfaceID) {
        case .pane(let location):
            return (location.pane.panel.id, location.pane.paneID.id, location.pane.panel)
        case .unresolvedMirror:
            return nil
        case .notRemote:
            if let panel = panels[surfaceID] {
                return (surfaceID, paneId(forPanelId: surfaceID)?.id, panel)
            }
            guard let dock = _dockSplit,
                  let panel = dock.panels[surfaceID] else {
                return nil
            }
            return (surfaceID, dock.paneId(forPanelId: surfaceID)?.id, panel)
        }
    }

    func controlTerminalTarget(for surfaceID: UUID) -> (surfaceID: UUID, panel: TerminalPanel)? {
        guard let target = controlSurfaceTarget(for: surfaceID),
              let panel = target.panel as? TerminalPanel else { return nil }
        return (target.surfaceID, panel)
    }

    func controlTerminalPanel(for surfaceID: UUID) -> TerminalPanel? {
        controlTerminalTarget(for: surfaceID)?.panel
    }

    /// Resolves a user input destination from either a workspace-owned panel
    /// or an explicit projected pane surface. Unlike stable control handles, a
    /// workspace container intentionally follows its authoritative active pane.
    func terminalInputTarget(
        forPanelID panelID: UUID
    ) -> (surfaceID: UUID, panel: TerminalPanel)? {
        let projection: ControlSurfaceProjection?
        if panels[panelID] != nil {
            projection = controlSurfaceProjection(forContainerPanelID: panelID)
        } else {
            projection = controlSurfaceTarget(for: panelID)
        }
        guard let projection,
              let panel = projection.panel as? TerminalPanel else { return nil }
        return (projection.surfaceID, panel)
    }

    /// Projects a workspace-owned panel into the identity exposed by the
    /// control plane. A mirror container resolves only when tmux has published
    /// an authoritative active pane; ordinary panels keep their Bonsplit pane.
    func controlSurfaceProjection(
        forContainerPanelID containerPanelID: UUID
    ) -> ControlSurfaceProjection? {
        if isRemoteTmuxControlContainer(containerPanelID) {
            return activeRemoteTmuxControlSurfaceProjection(
                containerPanelID: containerPanelID
            )
        }
        guard let panel = panels[containerPanelID] else { return nil }
        return (containerPanelID, paneId(forPanelId: containerPanelID)?.id, panel)
    }

    /// The terminal that currently owns keyboard input for this workspace.
    /// Workspace selection remains the stable outer identity, while a remote
    /// tmux container projects to its authoritative active inner pane.
    func focusedTerminalInputTarget() -> (surfaceID: UUID, panel: TerminalPanel)? {
        guard let focusedPanelId else { return nil }
        return terminalInputTarget(forPanelID: focusedPanelId)
    }

    /// Whether `surfaceID` is the workspace's canonical keyboard-input target.
    func isFocusedTerminalInputSurface(_ surfaceID: UUID) -> Bool {
        focusedTerminalInputTarget()?.surfaceID == surfaceID
    }

    /// Resolves the selected terminal target. A mirror container projects its
    /// active inner pane; a requested pane projects that pane's selected surface.
    func controlDefaultTerminalTarget(
        paneID requestedPaneID: UUID?
    ) -> (surfaceID: UUID, panel: TerminalPanel)? {
        if let requestedPaneID {
            if let remote = remoteTmuxControlPane(paneID: requestedPaneID) {
                return (remote.pane.panel.id, remote.pane.panel)
            }
            if let paneID = bonsplitController.allPaneIds.first(where: { $0.id == requestedPaneID }),
               let tab = bonsplitController.selectedTab(inPane: paneID),
               let panelID = panelIdFromSurfaceId(tab.id),
               !isRemoteTmuxControlContainer(panelID),
               let panel = terminalPanel(for: panelID) {
                return (panelID, panel)
            }
            return nil
        }

        return focusedTerminalInputTarget()
    }

    /// Resolves explicit-or-default control-plane surface targeting. An
    /// explicit surface id (or a routed tmux pane's surface) canonicalizes
    /// fail-closed via ``controlSurfaceTarget(for:)``; the focused default
    /// projects a mirror container to its tmux-active pane like
    /// `surface.current`. Returns nil when nothing is focused.
    func controlRequestedSurfaceTarget(
        explicitSurfaceID: UUID?,
        routedPaneID: UUID?
    ) -> (requestedSurfaceID: UUID, target: ControlSurfaceProjection?)? {
        if let explicit = explicitSurfaceID
            ?? routedPaneID.flatMap({ remoteTmuxControlPane(paneID: $0)?.pane.panel.id }) {
            return (explicit, controlSurfaceTarget(for: explicit))
        }
        guard let focusedPanelId else { return nil }
        return (focusedPanelId, controlSurfaceProjection(forContainerPanelID: focusedPanelId))
    }
}
