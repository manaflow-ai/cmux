public import CmuxMobileShellModel
public import Foundation

/// A one-shot "actually navigate to this workspace" intent from an external
/// terminal target, such as a notification tap or attach URL.
///
/// Setting `selectedWorkspaceID` alone is not enough on the compact (iPhone)
/// layout: the shell's `NavigationStack` deliberately ignores selection
/// changes while its path is empty so the attach-time auto-selection cannot
/// yank the user off the workspace list. External targets must push, so they
/// carry this explicit request, which the shell consumes exactly once. The
/// token makes repeated requests for the same workspace distinguishable.
public struct TerminalTargetWorkspaceNavigationRequest: Equatable, Sendable {
    public let token: UUID
    public let workspaceID: MobileWorkspacePreview.ID
}

extension CMUXMobileShellStore {
    /// Select `id` and ask the shell to navigate to it (push the compact
    /// stack). Called by the external target coordinator when a parked
    /// notification or attach target resolves; the workspace is expected to
    /// exist in ``workspaces``.
    public func navigateToWorkspaceForTerminalTarget(_ id: MobileWorkspacePreview.ID) {
        selectedWorkspaceID = id
        terminalTargetWorkspaceNavigationRequest = TerminalTargetWorkspaceNavigationRequest(
            token: UUID(),
            workspaceID: id
        )
    }

    /// Hand the pending terminal-target navigation intent to the shell and
    /// clear it so a later layout remount cannot replay a stale request.
    public func consumeTerminalTargetWorkspaceNavigationRequest() -> MobileWorkspacePreview.ID? {
        defer { terminalTargetWorkspaceNavigationRequest = nil }
        return terminalTargetWorkspaceNavigationRequest?.workspaceID
    }

    /// The terminal target carried by the currently connected attach ticket.
    /// The shell owns ticket decoding; UI coordinators use this value instead of
    /// decoding attach URLs a second time.
    public var activeAttachTerminalTarget: (workspaceId: String, surfaceId: String?)? {
        guard let activeTicket else { return nil }
        return (workspaceId: activeTicket.workspaceID, surfaceId: activeTicket.terminalID)
    }

    /// The workspace whose terminal list contains `surfaceID`, if any. Used by
    /// the external target coordinator to resolve surface-only targets to a
    /// navigable workspace, and to keep a target parked until the terminal's
    /// snapshot has arrived.
    public func workspaceID(containingSurfaceID surfaceID: String) -> MobileWorkspacePreview.ID? {
        workspaceID(forTerminalID: surfaceID)
    }

    /// Whether `surfaceID` is a terminal of the workspace `workspaceID`.
    public func workspace(_ workspaceID: MobileWorkspacePreview.ID, containsSurfaceID surfaceID: String) -> Bool {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else {
            return false
        }
        return workspace.terminals.contains(where: { $0.id.rawValue == surfaceID })
    }

    /// The workspace whose terminal list contains `terminalID`, if any.
    func workspaceID(forTerminalID terminalID: String) -> MobileWorkspacePreview.ID? {
        for workspace in workspaces {
            if workspace.terminals.contains(where: { $0.id.rawValue == terminalID }) {
                return workspace.id
            }
        }
        return nil
    }
}
