import Foundation

/// The phone-only side effect of a blocking Feed decision.
///
/// Feed keeps its actionable desktop banner in the Workstream store, so this
/// request deliberately carries only the content and target needed by the
/// phone push queue. It must not become a second terminal notification entry.
struct FeedPhonePushRequest: Equatable, Sendable {
    let title: String
    let subtitle: String
    let body: String
    let workspaceId: UUID?
    let surfaceId: UUID?
    let retargetsToLiveSurfaceOwner: Bool
    let replyShape: String
}

@MainActor
protocol FeedPhonePushForwarding {
    @discardableResult
    func forward(_ request: FeedPhonePushRequest) -> PhonePushForwardAdmission
}

@MainActor
struct DefaultFeedPhonePushForwarder: FeedPhonePushForwarding {
    func forward(_ request: FeedPhonePushRequest) -> PhonePushForwardAdmission {
        PhonePushClient.shared.forwardEphemeral(
            title: request.title,
            subtitle: request.subtitle,
            body: request.body,
            workspaceId: request.workspaceId,
            surfaceId: request.surfaceId,
            badgeCount: TerminalNotificationStore.shared.unreadNotificationCount,
            retargetsToLiveSurfaceOwner: request.retargetsToLiveSurfaceOwner,
            replyShape: request.replyShape
        )
    }
}
