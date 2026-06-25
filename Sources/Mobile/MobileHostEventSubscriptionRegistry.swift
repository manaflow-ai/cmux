import Foundation

/// Reference-counted registry of mobile event-topic subscriptions across all
/// live `MobileHostConnection`s.
///
/// Each connection adds its subscribed topics on `mobile.events.subscribe` and
/// removes them on unsubscribe/close. The registry keeps a per-topic refcount so
/// `hasSubscribers(topic:)` answers "does any connection want pushes for this
/// topic" without scanning every connection. When a topic transitions between
/// zero and nonzero subscribers it posts ``Notification/Name/mobileHostEventSubscriptionsDidChange``
/// so observers (e.g. `MobileTerminalRenderObserver`) can start or stop their
/// upstream work.
///
/// This is a constructor-injected instance, not a static namespace:
/// `MobileHostService` owns one and injects it into every `MobileHostConnection`
/// it creates, replacing the previous lock-guarded static-state namespace.
/// The instance state is guarded by an `NSLock` because the readers/writers run
/// across arbitrary actors and queues (connection actors, the nonisolated emit
/// path, and synchronous notification observers), so `@unchecked Sendable` is
/// justified by that single lock owning every access to `topicCounts`.
final class MobileHostEventSubscriptionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var topicCounts: [String: Int] = [:]

    init() {}

    func hasSubscribers(topic: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (topicCounts[topic] ?? 0) > 0
    }

    func replace(previousTopics: Set<String>?, nextTopics: Set<String>?) {
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

    func reset() {
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
    func resetForTesting() {
        reset()
    }
    #endif
}
