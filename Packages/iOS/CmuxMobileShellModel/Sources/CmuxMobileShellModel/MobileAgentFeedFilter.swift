/// User-selected projection over coding-agent activity.
public enum MobileAgentFeedFilter: Hashable, Sendable {
    case needsInput
    case allActivity

    public func apply(to items: [MobileAgentFeedItem]) -> [MobileAgentFeedItem] {
        switch self {
        case .needsInput:
            // Aggregation supplies newest-first rows. A stop remains replyable
            // only until a later event proves that workstream continued.
            var seenWorkstreams: Set<MobileAgentFeedWorkstreamScope> = []
            return items.filter { item in
                let isNewestForWorkstream = seenWorkstreams.insert(item.workstreamScope).inserted
                return item.wire.status.isPending
                    || (isNewestForWorkstream && item.isTurnCompletion)
            }
        case .allActivity:
            return items
        }
    }
}

private struct MobileAgentFeedWorkstreamScope: Hashable {
    let macDeviceID: String
    let macInstanceTag: String?
    let workstreamID: String
}

private extension MobileAgentFeedItem {
    var workstreamScope: MobileAgentFeedWorkstreamScope {
        MobileAgentFeedWorkstreamScope(
            macDeviceID: macDeviceID,
            macInstanceTag: macInstanceTag,
            workstreamID: wire.workstreamID
        )
    }
}
