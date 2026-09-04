public import Foundation

/// Deterministic grouping over a flat list of History events.
public struct VaultHistoryGrouper: Sendable {
    /// Stable identifier assigned to events missing the selected subject identity.
    public static let otherGroupID = VaultHistoryGroupIdentity.other.id

    private let calendar: Calendar

    /// Creates a grouper with an explicit calendar for deterministic boundaries.
    ///
    /// - Parameter calendar: Calendar used by date grouping.
    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// Groups events by one dimension after a single deterministic ordering pass.
    ///
    /// - Parameters:
    ///   - events: Flat recorded and derived event list.
    ///   - key: Dimension used to partition the list.
    ///   - now: Reference time used for date buckets.
    /// - Returns: Ordered groups whose events are newest first.
    public func groups(
        events: [VaultHistoryEvent],
        by key: VaultHistoryGroupKey,
        now: Date
    ) -> [VaultHistoryGroup] {
        groups(
            newestFirstEvents: events.sorted(by: VaultHistoryEvent.newestFirst),
            by: key,
            now: now
        )
    }

    /// Groups an already ordered event snapshot without another sorting pass.
    ///
    /// Use this overload when a timeline owner caches events in
    /// ``VaultHistoryEvent/newestFirst(_:_:)`` order and needs to regroup the
    /// same snapshot repeatedly.
    ///
    /// - Parameters:
    ///   - newestFirstEvents: Events already ordered newest first.
    ///   - key: Dimension used to partition the list.
    ///   - now: Reference time used for date buckets.
    /// - Returns: Ordered groups that preserve the supplied event order.
    public func groups(
        newestFirstEvents: [VaultHistoryEvent],
        by key: VaultHistoryGroupKey,
        now: Date
    ) -> [VaultHistoryGroup] {
        switch key {
        case .date:
            return dateGroups(events: newestFirstEvents, now: now)
        case .workspace:
            return identityGroups(events: newestFirstEvents, key: key) { event in
                event.subject.workspaceId.map(VaultHistoryGroupIdentity.workspace) ?? .other
            }
        case .window:
            return identityGroups(events: newestFirstEvents, key: key) { event in
                event.subject.windowId.map(VaultHistoryGroupIdentity.window) ?? .other
            }
        case .agent:
            return identityGroups(events: newestFirstEvents, key: key) { event in
                guard let agent = event.subject.agent?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !agent.isEmpty else {
                    return .other
                }
                return .agent(agent)
            }
        case .kind:
            return identityGroups(events: newestFirstEvents, key: key) { event in
                .kind(event.kind)
            }
        }
    }

    private func dateGroups(
        events: [VaultHistoryEvent],
        now: Date
    ) -> [VaultHistoryGroup] {
        var eventsByBucket: [VaultHistoryDateBucket: [VaultHistoryEvent]] = [:]
        for event in events {
            let bucket = VaultHistoryDateBucket.bucket(
                for: event.timestamp,
                now: now,
                calendar: calendar
            )
            eventsByBucket[bucket, default: []].append(event)
        }
        return VaultHistoryDateBucket.allCases.compactMap { bucket in
            guard let events = eventsByBucket[bucket], !events.isEmpty else {
                return nil
            }
            return VaultHistoryGroup(key: .date, identity: .date(bucket), events: events)
        }
    }

    private func identityGroups(
        events: [VaultHistoryEvent],
        key: VaultHistoryGroupKey,
        identityForEvent: (VaultHistoryEvent) -> VaultHistoryGroupIdentity
    ) -> [VaultHistoryGroup] {
        var order: [VaultHistoryGroupIdentity] = []
        var eventsByIdentity: [VaultHistoryGroupIdentity: [VaultHistoryEvent]] = [:]
        for event in events {
            let identity = identityForEvent(event)
            if eventsByIdentity[identity] == nil {
                order.append(identity)
            }
            eventsByIdentity[identity, default: []].append(event)
        }
        if let otherIndex = order.firstIndex(of: .other), otherIndex != order.count - 1 {
            order.remove(at: otherIndex)
            order.append(.other)
        }
        return order.compactMap { identity in
            guard let events = eventsByIdentity[identity], !events.isEmpty else {
                return nil
            }
            return VaultHistoryGroup(key: key, identity: identity, events: events)
        }
    }
}
