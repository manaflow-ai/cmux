public import CMUXMobileCore

/// Publishes selected-workspace viewing state independently of device discovery.
@MainActor
public protocol WorkspacePresenceAnnouncing: Sendable {
    func setWorkspaceScope(_ scope: WorkspacePresenceScope?) async
    func setWorkspaceViewing(_ active: Bool)
}
