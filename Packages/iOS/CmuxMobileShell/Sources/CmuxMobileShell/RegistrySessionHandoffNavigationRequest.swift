public import CmuxMobileShellModel
public import Foundation

/// A one-shot navigation intent for the exact agent conversation chosen during registry handoff.
public struct RegistrySessionHandoffNavigationRequest: Equatable, Sendable {
    /// Distinguishes repeated handoffs to the same session.
    public let token: UUID
    /// Aggregate workspace row the shell is opening.
    public let workspaceID: MobileWorkspacePreview.ID
    /// Authoritative agent-session identity to pin in chat mode.
    public let agentSessionID: String
}
