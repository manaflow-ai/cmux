import Bonsplit
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
        let locations = remoteTmuxControlPanes(containerPanelID: containerPanelID)
        return locations.first(where: { $0.pane.isFocused }) ?? locations.first
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

    /// Canonicalizes an explicit control-plane terminal target. Hidden mirror
    /// containers fail closed instead of exposing their stale wrapper panel.
    func controlSurfaceTarget(for surfaceID: UUID) -> ControlSurfaceProjection? {
        switch remoteTmuxControlSurfaceTarget(surfaceID: surfaceID) {
        case .pane(let location):
            return (location.pane.panel.id, location.pane.paneID.id, location.pane.panel)
        case .unresolvedMirror:
            return nil
        case .notRemote:
            guard let panel = panels[surfaceID] else { return nil }
            return (surfaceID, paneId(forPanelId: surfaceID)?.id, panel)
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

    /// Projects a workspace-owned panel into the identity exposed by the
    /// control plane. A mirror container resolves only when tmux has published
    /// an authoritative active pane; ordinary panels keep their Bonsplit pane.
    func controlSurfaceProjection(
        forContainerPanelID containerPanelID: UUID
    ) -> ControlSurfaceProjection? {
        if isRemoteTmuxControlContainer(containerPanelID) {
            guard let active = activeRemoteTmuxControlPane(containerPanelID: containerPanelID) else {
                return nil
            }
            return (active.pane.panel.id, active.pane.paneID.id, active.pane.panel)
        }
        guard let panel = panels[containerPanelID] else { return nil }
        return (containerPanelID, paneId(forPanelId: containerPanelID)?.id, panel)
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

        guard let focusedPanelId,
              let projection = controlSurfaceProjection(forContainerPanelID: focusedPanelId),
              let panel = projection.panel as? TerminalPanel else { return nil }
        return (projection.surfaceID, panel)
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
