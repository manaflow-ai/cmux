#if os(iOS)
import Foundation

/// The five CMUX Labs presentations available for the iOS agent Feed.
enum MobileAgentFeedDesign: String, CaseIterable, Identifiable {
    case timeline
    case cards
    case compact
    case conversation
    case commandCenter

    static let storageKey = "cmux.labs.agentFeedDesign"

    var id: String { rawValue }

    func title(using localizer: AgentFeedLocalizer) -> String {
        switch self {
        case .timeline:
            localizer.string("mobile.agentFeed.design.timeline", defaultValue: "Timeline")
        case .cards:
            localizer.string("mobile.agentFeed.design.cards", defaultValue: "Cards")
        case .compact:
            localizer.string("mobile.agentFeed.design.compact", defaultValue: "Compact")
        case .conversation:
            localizer.string("mobile.agentFeed.design.conversation", defaultValue: "Conversation")
        case .commandCenter:
            localizer.string("mobile.agentFeed.design.commandCenter", defaultValue: "Command Center")
        }
    }
}
#endif
