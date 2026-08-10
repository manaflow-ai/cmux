/// User-selected projection over coding-agent activity.
public enum MobileAgentFeedFilter: Hashable, Sendable {
    case needsInput
    case allActivity

    public func apply(to items: [MobileAgentFeedItem]) -> [MobileAgentFeedItem] {
        switch self {
        case .needsInput: items.filter(\.isActionable)
        case .allActivity: items
        }
    }
}
