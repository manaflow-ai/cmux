import Foundation

/// Serializes notification-policy completion by cooldown key when present,
/// otherwise by the same user-visible delivery destination.
enum TerminalNotificationPolicyDeliveryIdentity: Hashable, Sendable {
    case cooldown(String)
    case surface(UUID)
    case workspace(UUID)

    init(request: TerminalNotificationPolicyRequest, cooldownKey: String?) {
        if let cooldownKey {
            self = .cooldown(cooldownKey)
        } else {
            self.init(request: request)
        }
    }

    init(request: TerminalNotificationPolicyRequest) {
        if let surfaceId = request.panelId ?? request.surfaceId {
            self = .surface(surfaceId)
        } else {
            self = .workspace(request.tabId)
        }
    }
}
