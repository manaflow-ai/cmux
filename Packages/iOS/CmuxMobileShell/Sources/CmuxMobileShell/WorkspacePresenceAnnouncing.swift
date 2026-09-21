public import CMUXMobileCore

/// Publishes selected-workspace viewing state independently of device discovery.
public protocol WorkspacePresenceAnnouncing: Sendable {
    func setWorkspaceScope(_ scope: WorkspacePresenceScope?) async
}
