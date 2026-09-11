public import CMUXMobileCore
public import CmuxMobileShellModel
import Foundation

/// The phone-side selection to apply after opening an external navigation URL.
public enum MobileExternalNavigationSelection: Equatable, Sendable {
    /// Select a terminal surface.
    case terminal(MobileTerminalPreview.ID)
    /// Select a non-terminal Mac surface.
    case surface(MobileSurfacePreview.ID)
}

/// The resolved workspace and optional child selection for one navigation URL.
public struct MobileExternalNavigationResolution: Equatable, Sendable {
    /// The current UI row id to select.
    public let workspaceID: MobileWorkspacePreview.ID
    /// The child surface to select, when the URL names one.
    public let selection: MobileExternalNavigationSelection?

    /// Creates a navigation resolution.
    public init(
        workspaceID: MobileWorkspacePreview.ID,
        selection: MobileExternalNavigationSelection?
    ) {
        self.workspaceID = workspaceID
        self.selection = selection
    }
}

/// Pure workspace-list lookup for external workspace, pane, and surface links.
///
/// The resolver deliberately returns `.unavailable` when an identity is not in
/// the current snapshot. The root scene parks the original URL and retries when
/// the workspace topology changes, which covers cold launch and attach races.
public struct MobileExternalNavigationTargetResolver: Sendable {
    /// Whether a request found a current target.
    public enum ResolutionResult: Equatable, Sendable {
        /// The target can be applied now.
        case resolved(MobileExternalNavigationResolution)
        /// The workspace or child has not arrived in the current snapshot.
        case unavailable
    }

    private let workspaces: [MobileWorkspacePreview]

    /// Creates a resolver over one immutable workspace snapshot.
    public init(workspaces: [MobileWorkspacePreview]) {
        self.workspaces = workspaces
    }

    /// Resolves one parsed navigation request.
    public func resolve(_ request: CmxNavigationURLRequest) -> ResolutionResult {
        switch request.target {
        case .workspace(let workspaceID):
            guard let workspace = workspace(
                runtimeID: workspaceID,
                stableFallbackID: request.stableFallbackWorkspaceId
            ) else { return .unavailable }
            return .resolved(.init(workspaceID: workspace.id, selection: nil))

        case .surface(let workspaceID, let surfaceID):
            guard let workspace = workspace(
                runtimeID: workspaceID,
                stableFallbackID: request.stableFallbackWorkspaceId
            ) else {
                return resolveSurfaceAcrossWorkspaces(
                    surfaceID: surfaceID,
                    stableSurfaceID: request.stableFallbackSurfaceId
                )
            }
            if let selection = selection(
                surfaceID: surfaceID,
                in: workspace
            ) {
                return .resolved(.init(workspaceID: workspace.id, selection: selection))
            }
            if let stableSurfaceID = request.stableFallbackSurfaceId,
               let selection = selection(surfaceID: stableSurfaceID, in: workspace) {
                return .resolved(.init(workspaceID: workspace.id, selection: selection))
            }
            return resolveSurfaceAcrossWorkspaces(
                surfaceID: surfaceID,
                stableSurfaceID: request.stableFallbackSurfaceId,
                excluding: workspace.id
            )

        case .pane(let workspaceID, let paneID):
            guard let workspace = workspace(
                runtimeID: workspaceID,
                stableFallbackID: request.stableFallbackWorkspaceId
            ) else { return .unavailable }
            let paneID = paneID.uuidString.lowercased()
            let paneSurfaces = workspace.surfaces.filter {
                $0.paneID?.rawValue.lowercased() == paneID
            }
            if let surface = preferredSurface(in: paneSurfaces, workspace: workspace) {
                return .resolved(.init(
                    workspaceID: workspace.id,
                    selection: selection(for: surface, workspace: workspace)
                ))
            }

            // Hosts predating pane metadata can still honor the workspace part
            // of a pane URL. This is preferable to sending a recognized link
            // through the pairing connector, and newer hosts retry above once
            // their pane inventory arrives.
            if workspace.surfaces.allSatisfy({ $0.paneID == nil }) {
                return .resolved(.init(workspaceID: workspace.id, selection: nil))
            }
            return .unavailable
        }
    }

    private func workspace(
        runtimeID: UUID,
        stableFallbackID: UUID?
    ) -> MobileWorkspacePreview? {
        let runtimeMatches = uniqueWorkspaces {
            identifiersMatch($0.rpcWorkspaceID.rawValue, runtimeID)
        }
        if let runtimeMatches { return runtimeMatches }

        // Workspace links copied from the Mac intentionally put the durable
        // identity in the path (there is no query fallback on those links).
        // Prefer that identity after the current-session id, matching the Mac
        // resolver's runtime-before-stable rule.
        let pathStableMatches = uniqueWorkspaces {
            let stableID = $0.stableID?.rawValue ?? $0.id.rawValue
            return identifiersMatch(stableID, runtimeID)
        }
        if let pathStableMatches { return pathStableMatches }

        guard let stableFallbackID else { return nil }
        return uniqueWorkspaces {
            let stableID = $0.stableID?.rawValue ?? $0.id.rawValue
            return identifiersMatch(stableID, stableFallbackID)
        }
    }

    private func uniqueWorkspaces(
        where predicate: (MobileWorkspacePreview) -> Bool
    ) -> MobileWorkspacePreview? {
        let matches = workspaces.filter(predicate)
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private func resolveSurfaceAcrossWorkspaces(
        surfaceID: UUID,
        stableSurfaceID: UUID?,
        excluding excludedWorkspaceID: MobileWorkspacePreview.ID? = nil
    ) -> ResolutionResult {
        let runtimeMatches = workspaces.filter { workspace in
            workspace.id != excludedWorkspaceID
                && selection(surfaceID: surfaceID, in: workspace) != nil
        }
        if runtimeMatches.count == 1,
           let selection = selection(surfaceID: surfaceID, in: runtimeMatches[0]) {
            return .resolved(.init(workspaceID: runtimeMatches[0].id, selection: selection))
        }
        guard let stableSurfaceID else { return .unavailable }
        let stableMatches = workspaces.filter { workspace in
            workspace.id != excludedWorkspaceID
                && selection(surfaceID: stableSurfaceID, in: workspace) != nil
        }
        guard stableMatches.count == 1,
              let selection = selection(surfaceID: stableSurfaceID, in: stableMatches[0]) else {
            return .unavailable
        }
        return .resolved(.init(workspaceID: stableMatches[0].id, selection: selection))
    }

    private func selection(
        surfaceID: UUID,
        in workspace: MobileWorkspacePreview
    ) -> MobileExternalNavigationSelection? {
        if let terminal = workspace.terminals.first(where: {
            identifiersMatch($0.id.rawValue, surfaceID)
        }) {
            return .terminal(terminal.id)
        }
        if let surface = workspace.surfaces.first(where: {
            identifiersMatch($0.id.rawValue, surfaceID)
                || ($0.stableID.map { identifiersMatch($0.rawValue, surfaceID) } ?? false)
        }) {
            return selection(for: surface, workspace: workspace)
        }
        return nil
    }

    private func identifiersMatch(_ rawValue: String, _ id: UUID) -> Bool {
        identifiersMatch(rawValue, id.uuidString)
    }

    private func identifiersMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    private func selection(
        for surface: MobileSurfacePreview,
        workspace: MobileWorkspacePreview
    ) -> MobileExternalNavigationSelection {
        if let terminal = workspace.terminals.first(where: {
            identifiersMatch($0.id.rawValue, surface.id.rawValue)
        }) {
            return .terminal(terminal.id)
        }
        return .surface(surface.id)
    }

    private func preferredSurface(
        in surfaces: [MobileSurfacePreview],
        workspace: MobileWorkspacePreview
    ) -> MobileSurfacePreview? {
        surfaces.first(where: { $0.isFocused })
            ?? surfaces.first(where: { surface in
                workspace.terminals.contains(where: { terminal in
                    identifiersMatch(terminal.id.rawValue, surface.id.rawValue)
                })
            })
            ?? surfaces.first
    }
}
