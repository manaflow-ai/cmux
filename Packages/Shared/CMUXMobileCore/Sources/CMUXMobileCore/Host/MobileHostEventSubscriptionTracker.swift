import Foundation

extension Notification.Name {
    /// Posted whenever the set of topics with at least one live mobile-client
    /// subscription changes (a topic gains its first subscriber or loses its
    /// last). The desktop terminal render observer listens so Ghostty
    /// notification demand is tied to active subscriptions; the `userInfo`
    /// `"topics"` key carries the sorted list of topics whose active/inactive
    /// state flipped.
    public static let mobileHostEventSubscriptionsDidChange = Notification.Name(
        "cmux.mobileHostEventSubscriptionsDidChange"
    )
}

/// Process-wide per-topic subscriber counts for the mobile pairing host: how
/// many live mobile-client subscriptions reference each event topic. The host's
/// emit path reads ``hasSubscribers(topic:)`` to skip work for topics no phone
/// is watching, and each connection's subscribe/unsubscribe path calls
/// ``replace(previousTopics:nextTopics:)`` to keep the counts current. Whenever
/// a topic crosses the zero boundary (first subscriber arrives or last one
/// leaves) the tracker posts ``Notification/Name/mobileHostEventSubscriptionsDidChange``
/// so the desktop render observer can raise or release Ghostty notification
/// demand.
///
/// A real instance type replacing the former caseless-enum namespace; the app
/// holds one process-wide default at its composition point and threads it to the
/// decoupled subsystems that share this state (the host service's emit path and
/// each `MobileHostConnection`'s subscription path). Access is guarded by a
/// small `NSLock` rather than an actor because every reader is a synchronous,
/// non-`async` caller (`hasSubscribers` runs inside the synchronous emit turn
/// and cannot await), and the guarded state is one tiny `[String: Int]` counter:
/// the sanctioned lock-for-tiny-values-read-by-synchronous-code shape.
/// `@unchecked Sendable` is justified because the `NSLock` serializes every read
/// and write of the counter dictionary.
public final class MobileHostEventSubscriptionTracker: @unchecked Sendable {
    // lint:allow lock — synchronous cross-actor subscription registry read on
    // the event-emit path; an actor would async-ify the synchronous emit checks.
    private let lock = NSLock()
    private var topicCounts: [String: Int] = [:]

    /// Creates a tracker with no subscriptions recorded.
    public init() {}

    /// True while at least one live mobile-client subscription references `topic`.
    public func hasSubscribers(topic: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (topicCounts[topic] ?? 0) > 0
    }

    /// Applies a connection's subscription change, decrementing the count for
    /// every topic in `previousTopics` and incrementing it for every topic in
    /// `nextTopics`, then posts
    /// ``Notification/Name/mobileHostEventSubscriptionsDidChange`` if any topic
    /// crossed the zero boundary.
    public func replace(previousTopics: Set<String>?, nextTopics: Set<String>?) {
        let changedTopics = updateCounts(previousTopics: previousTopics, nextTopics: nextTopics)
        guard !changedTopics.isEmpty else { return }
        NotificationCenter.default.post(
            name: .mobileHostEventSubscriptionsDidChange,
            object: nil,
            userInfo: ["topics": Array(changedTopics).sorted()]
        )
    }

    private func updateCounts(previousTopics: Set<String>?, nextTopics: Set<String>?) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }

        var changedTopics = Set<String>()
        let allTopics = Set(previousTopics ?? []).union(nextTopics ?? [])
        let before = Dictionary(uniqueKeysWithValues: allTopics.map { ($0, topicCounts[$0] ?? 0) })

        for topic in previousTopics ?? [] {
            let nextCount = max(0, (topicCounts[topic] ?? 0) - 1)
            if nextCount == 0 {
                topicCounts.removeValue(forKey: topic)
            } else {
                topicCounts[topic] = nextCount
            }
        }
        for topic in nextTopics ?? [] {
            topicCounts[topic] = (topicCounts[topic] ?? 0) + 1
        }

        for topic in allTopics {
            let wasActive = (before[topic] ?? 0) > 0
            let isActive = (topicCounts[topic] ?? 0) > 0
            if wasActive != isActive {
                changedTopics.insert(topic)
            }
        }
        return changedTopics
    }

    /// Clears every subscription count and posts
    /// ``Notification/Name/mobileHostEventSubscriptionsDidChange`` with an empty
    /// topics list (used when the host stops).
    public func reset() {
        lock.lock()
        topicCounts.removeAll()
        lock.unlock()
        NotificationCenter.default.post(
            name: .mobileHostEventSubscriptionsDidChange,
            object: nil,
            userInfo: ["topics": []]
        )
    }

    #if DEBUG
    /// Clears every subscription count. Test-only.
    public func resetForTesting() {
        reset()
    }
    #endif
}
