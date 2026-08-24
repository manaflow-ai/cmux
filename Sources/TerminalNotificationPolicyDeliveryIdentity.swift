import Foundation

/// Serializes notification-policy completion only with work that targets the
/// same user-visible delivery destination.
enum TerminalNotificationPolicyDeliveryIdentity: Hashable, Sendable {
    case surface(UUID)
    case workspace(UUID)

    init(request: TerminalNotificationPolicyRequest) {
        if let surfaceId = request.panelId ?? request.surfaceId {
            self = .surface(surfaceId)
        } else {
            self = .workspace(request.tabId)
        }
    }
}
