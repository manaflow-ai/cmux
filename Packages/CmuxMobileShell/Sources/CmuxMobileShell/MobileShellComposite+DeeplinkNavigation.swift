public import CmuxMobileShellModel
public import Foundation

/// A one-shot "actually navigate to this workspace" intent from a
/// notification-tap deep link.
///
/// Setting `selectedWorkspaceID` alone is not enough on the compact (iPhone)
/// layout: the shell's `NavigationStack` deliberately ignores selection
/// changes while its path is empty so the attach-time auto-selection cannot
/// yank the user off the workspace list. A deep link must push, so it carries
/// this explicit request, which the shell consumes exactly once. The token
/// makes repeated taps on the same workspace distinguishable.
public struct DeeplinkWorkspaceNavigationRequest: Equatable, Sendable {
    public let token: UUID
    public let workspaceID: MobileWorkspacePreview.ID
}

extension CMUXMobileShellStore {
    /// Select `id` and ask the shell to navigate to it (push the compact
    /// stack). Called by the push coordinator when a parked notification tap
    /// resolves; the workspace is expected to exist in ``workspaces``.
    public func navigateToWorkspaceForDeeplink(_ id: MobileWorkspacePreview.ID) {
        selectedWorkspaceID = id
        deeplinkWorkspaceNavigationRequest = DeeplinkWorkspaceNavigationRequest(
            token: UUID(),
            workspaceID: id
        )
    }

    /// Hand the pending deep-link navigation intent to the shell and clear it
    /// so a later layout remount cannot replay a stale push.
    public func consumeDeeplinkWorkspaceNavigationRequest() -> MobileWorkspacePreview.ID? {
        defer { deeplinkWorkspaceNavigationRequest = nil }
        return deeplinkWorkspaceNavigationRequest?.workspaceID
    }

    /// The workspace whose terminal list contains `surfaceID`, if any. Used by
    /// the push coordinator to resolve surface-only notification deep links to
    /// a navigable workspace, and to keep a tap parked until the terminal's
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
