public import CmuxMobileShellModel
public import Observation

/// Serializes authoritative terminal reorders across hierarchy presentations.
@MainActor
@Observable
public final class MobileTerminalReorderGate {
    private(set) var activeWorkspaceID: MobileWorkspacePreview.ID?
    private(set) var activePaneID: MobilePanePreview.ID?

    /// Creates an inactive reorder gate.
    public init() {}

    /// Whether an authoritative reorder is still in flight.
    public var isActive: Bool { activeWorkspaceID != nil }

    func begin(
        workspaceID: MobileWorkspacePreview.ID,
        paneID: MobilePanePreview.ID
    ) -> Bool {
        guard !isActive else { return false }
        activeWorkspaceID = workspaceID
        activePaneID = paneID
        return true
    }

    func finish(
        workspaceID: MobileWorkspacePreview.ID,
        paneID: MobilePanePreview.ID
    ) {
        guard activeWorkspaceID == workspaceID, activePaneID == paneID else { return }
        activeWorkspaceID = nil
        activePaneID = nil
    }
}
