#if os(iOS)
import CmuxMobileSupport
import Foundation

/// The five Labs presentations available for the iOS notification feed.
enum MobileNotificationFeedDesign: String, CaseIterable, Identifiable {
    case timeline
    case cards
    case compact
    case conversation
    case commandCenter

    static let storageKey = "cmux.labs.notificationFeedDesign"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .timeline:
            L10n.string("mobile.notificationFeed.design.timeline", defaultValue: "Timeline")
        case .cards:
            L10n.string("mobile.notificationFeed.design.cards", defaultValue: "Cards")
        case .compact:
            L10n.string("mobile.notificationFeed.design.compact", defaultValue: "Compact")
        case .conversation:
            L10n.string("mobile.notificationFeed.design.conversation", defaultValue: "Conversation")
        case .commandCenter:
            L10n.string("mobile.notificationFeed.design.commandCenter", defaultValue: "Command Center")
        }
    }
}
#endif
