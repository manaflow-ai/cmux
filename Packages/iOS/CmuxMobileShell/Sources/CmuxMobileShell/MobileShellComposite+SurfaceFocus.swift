internal import CmuxMobileRPC
public import CmuxMobileShellModel

extension MobileShellComposite {
    public nonisolated static let surfaceFocusCapability = "surface.focus.v1"

    /// Shows a Mac surface in the workspace detail. Deliberately leaves
    /// ``selectedTerminalID`` alone so the terminal selection (and composer
    /// draft) survives the surface visit.
    public func selectMacSurface(_ surfaceID: MobileSurfacePreview.ID) {
        selectedMacSurfaceID = surfaceID
    }

    /// Whether the workspace's owning Mac advertises surface focus.
    public func supportsSurfaceFocus(in workspaceID: MobileWorkspacePreview.ID) -> Bool {
        let target = workspaceMutationTarget(for: workspaceID)
        if target.isForeground {
            return supportedHostCapabilities.contains(Self.surfaceFocusCapability)
        }
        guard let ownerKey = target.ownerKey else { return false }
        return secondaryMacSubscriptions[ownerKey]?.supportedHostCapabilities.contains(Self.surfaceFocusCapability) == true
    }

    /// Focuses a surface on the owning Mac. Returns false when the host is
    /// unsupported or unreachable, or the RPC fails, so callers can show the
    /// user that nothing happened on the Mac.
    @discardableResult
    public func focusSurfaceOnMac(
        workspaceID: MobileWorkspacePreview.ID,
        surfaceID: MobileSurfacePreview.ID
    ) async -> Bool {
        guard supportsSurfaceFocus(in: workspaceID),
              let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return false }
        let target = workspaceMutationTarget(for: workspaceID)
        guard let client = target.client else { return false }
        do {
            try await client.focusSurface(
                workspaceID: workspace.rpcWorkspaceID.rawValue,
                surfaceID: surfaceID.rawValue
            )
            return true
        } catch {
            if target.isForeground { markMacConnectionUnavailableIfNeeded(after: error) }
            return false
        }
    }
}
