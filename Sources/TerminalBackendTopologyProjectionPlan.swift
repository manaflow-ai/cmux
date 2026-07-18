import CmuxTerminalBackend
import Foundation

/// A fully validated, immutable projection plan built before live Swift state changes.
struct TerminalBackendTopologyProjectionPlan: Equatable, Sendable {
    struct Workspace: Equatable, Sendable {
        let canonical: CanonicalWorkspace
        /// Canonical screens retained in daemon order. Swift currently
        /// presents the first screen and keeps the remaining screens as dormant
        /// value state, so they create no AppKit or renderer objects.
        let screens: [CanonicalScreen]
        let screen: CanonicalScreen
        /// Every daemon-owned surface in every screen. Only `screen` is
        /// materialized, but dormant canonical endpoints must never be
        /// mistaken for client-owned overlays.
        let allCanonicalSurfaceIDs: Set<UUID>
    }

    let workspaces: [Workspace]
    let placements: Set<TerminalBackendTopologyPlacement>
    /// Stable canonical surface-to-workspace ownership, including dormant
    /// screens. Built with the structural plan off the main actor.
    let surfaceWorkspaceIDs: [SurfaceID: UUID]

    private init(
        workspaces: [Workspace],
        placements: Set<TerminalBackendTopologyPlacement>,
        surfaceWorkspaceIDs: [SurfaceID: UUID]
    ) {
        self.workspaces = workspaces
        self.placements = placements
        self.surfaceWorkspaceIDs = surfaceWorkspaceIDs
    }

    init(topology: CanonicalTopology) throws {
        var workspaces: [Workspace] = []
        var placements: Set<TerminalBackendTopologyPlacement> = []
        var surfaceWorkspaceIDs: [SurfaceID: UUID] = [:]

        for workspace in topology.workspaces {
            try Task.checkCancellation()
            let workspaceID = workspace.uuid.rawValue
            var allCanonicalSurfaceIDs: Set<UUID> = []
            for canonicalScreen in workspace.screens {
                try Task.checkCancellation()
                for pane in canonicalScreen.panes {
                    for surface in pane.tabs {
                        guard allCanonicalSurfaceIDs.insert(surface.uuid.rawValue).inserted,
                              surfaceWorkspaceIDs.updateValue(
                                workspaceID,
                                forKey: surface.uuid
                              ) == nil else {
                            throw TerminalBackendTopologyProjectionError.projectionFailed(
                                "one canonical surface belongs to multiple workspaces"
                            )
                        }
                    }
                }
            }
            guard let screen = workspace.screens.first else { continue }
            // Swift currently presents exactly one screen per workspace. Keep
            // later screens as daemon-owned dormant value state, but authorize
            // only terminals that this projection can actually materialize.
            for pane in screen.panes {
                try Task.checkCancellation()
                for surface in pane.tabs {
                    guard Self.isTerminalKind(surface.kind) else { continue }
                    let placement = TerminalBackendTopologyPlacement(
                        workspaceID: workspace.uuid.rawValue,
                        surfaceID: surface.uuid.rawValue
                    )
                    guard placements.insert(placement).inserted else {
                        throw TerminalBackendTopologyProjectionError.duplicatePlacement(placement)
                    }
                }
            }
            workspaces.append(Workspace(
                canonical: workspace,
                screens: workspace.screens,
                screen: screen,
                allCanonicalSurfaceIDs: allCanonicalSurfaceIDs
            ))
        }

        self.workspaces = workspaces
        self.placements = placements
        self.surfaceWorkspaceIDs = surfaceWorkspaceIDs
    }

    func selectingWorkspaces(_ workspaceIDs: Set<UUID>) throws -> Self {
        var selected: [Workspace] = []
        selected.reserveCapacity(min(workspaces.count, workspaceIDs.count))
        for workspace in workspaces {
            try Task.checkCancellation()
            if workspaceIDs.contains(workspace.canonical.uuid.rawValue) {
                selected.append(workspace)
            }
        }
        return Self(
            workspaces: selected,
            placements: Set(placements.filter {
                workspaceIDs.contains($0.workspaceID)
            }),
            surfaceWorkspaceIDs: surfaceWorkspaceIDs.filter {
                workspaceIDs.contains($0.value)
            }
        )
    }

    func selectingScreens(_ screenIDsByWorkspace: [UUID: UUID]) throws -> Self {
        var selectedWorkspaces: [Workspace] = []
        var selectedPlacements: Set<TerminalBackendTopologyPlacement> = []
        selectedWorkspaces.reserveCapacity(workspaces.count)
        selectedPlacements.reserveCapacity(placements.count)
        for workspace in workspaces {
            try Task.checkCancellation()
            let workspaceID = workspace.canonical.uuid.rawValue
            let selectedScreen: CanonicalScreen
            if let selectedScreenID = screenIDsByWorkspace[workspaceID] {
                guard let match = workspace.screens.first(where: {
                    $0.uuid.rawValue == selectedScreenID
                }) else {
                    throw TerminalBackendTopologyProjectionError.projectionFailed(
                        "selected backend screen is no longer part of its workspace"
                    )
                }
                selectedScreen = match
            } else {
                selectedScreen = workspace.screen
            }
            for pane in selectedScreen.panes {
                try Task.checkCancellation()
                for surface in pane.tabs where Self.isTerminalKind(surface.kind) {
                    let placement = TerminalBackendTopologyPlacement(
                        workspaceID: workspaceID,
                        surfaceID: surface.uuid.rawValue
                    )
                    guard selectedPlacements.insert(placement).inserted else {
                        throw TerminalBackendTopologyProjectionError.duplicatePlacement(placement)
                    }
                }
            }
            selectedWorkspaces.append(Workspace(
                canonical: workspace.canonical,
                screens: workspace.screens,
                screen: selectedScreen,
                allCanonicalSurfaceIDs: workspace.allCanonicalSurfaceIDs
            ))
        }
        return Self(
            workspaces: selectedWorkspaces,
            placements: selectedPlacements,
            surfaceWorkspaceIDs: surfaceWorkspaceIDs
        )
    }

    private static func isTerminalKind(_ kind: String) -> Bool {
        switch kind.lowercased() {
        case "pty", "terminal":
            true
        default:
            false
        }
    }

}
