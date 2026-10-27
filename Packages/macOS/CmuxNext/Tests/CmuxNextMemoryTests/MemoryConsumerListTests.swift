import CmuxNextCompat
import CmuxNextMemory
import Testing

/// ``MemoryConsumerList`` keeps the live consumers in registration order (or its owner's order, ties
/// in registration order) and drops a released one on its next add or walk, so registrations that
/// come and go never grow the list.
@MainActor @Suite struct MemoryConsumerListTests {
    @Test func anOrderedListInsertsInItsOrderAndKeepsTiesInRegistrationOrder() {
        // Shorter names go first; equal lengths keep registration order.
        let registry = ListRegistry(list: MemoryConsumerList(orderedBy: { $0.name.count < $1.name.count }))
        let names = ["ccc", "a1", "bbbb", "a2", "d", "a3"]
        let consumers = names.map { _ in Consumer() }
        let registrations = zip(consumers, names).map { consumer, name in registry.register(consumer, name: name) }
        #expect(registry.list.liveEntries().map(\.name) == ["d", "a1", "a2", "a3", "ccc", "bbbb"])
        registrations[1].cancel()
        _ = registry.register(Consumer(), name: "e")
        #expect(registry.list.liveEntries().map(\.name) == ["d", "a2", "a3", "ccc", "bbbb"])
        withExtendedLifetime((consumers, registrations)) {}
    }

    @Test func liveEntriesKeepRegistrationOrder() {
        let registry = ListRegistry()
        let consumers = (0..<3).map { _ in Consumer() }
        let registrations = consumers.enumerated().map { index, consumer in registry.register(consumer, name: "c\(index)") }
        #expect(registry.list.liveEntries().map(\.name) == ["c0", "c1", "c2"])
        #expect(consumers.allSatisfy { $0.limits == [.default] }, "a new consumer did not get the current limit")
        withExtendedLifetime(registrations) {}
    }

    @Test func aCancelledEntryIsDroppedOnTheNextWalk() {
        let registry = ListRegistry()
        let first = Consumer()
        let second = Consumer()
        let registrations = [registry.register(first, name: "first"), registry.register(second, name: "second")]
        registrations[0].cancel()
        #expect(registry.list.storedCount == 2)
        #expect(registry.list.liveEntries().map(\.name) == ["second"])
        #expect(registry.list.storedCount == 1)
        withExtendedLifetime(registrations) {}
    }

    @Test func registrationsThatComeAndGoNeverGrowTheList() {
        let registry = ListRegistry()
        let consumer = Consumer()
        let kept = registry.register(consumer, name: "kept")
        for index in 0..<100 {
            _ = registry.register(Consumer(), name: "gone\(index)")
        }
        #expect(registry.list.storedCount <= 2, "released registrations stayed in the list")
        #expect(registry.list.liveEntries().map(\.name) == ["kept"])
        withExtendedLifetime(kept) {}
    }
}

/// A consumer that records each limit it got.
private final class Consumer: MemoryConsumer {
    var limits: [MemoryLimit] = []

    func updateMemoryLimit(_ limit: MemoryLimit) {
        limits.append(limit)
    }

    func releaseMemory(within _: MemoryReleaseSlice) -> MemoryReleaseProgress {
        .done
    }

    var memoryUsage: MemoryUsage? {
        .empty
    }
}

/// A registry over one ``MemoryConsumerList`` that hands each new consumer the default limit.
private final class ListRegistry: MemoryConsumerRegistry {
    let list: MemoryConsumerList<MemoryConsumerEntry>

    init(list: MemoryConsumerList<MemoryConsumerEntry> = MemoryConsumerList()) {
        self.list = list
    }

    func addMemoryConsumer(_ entry: MemoryConsumerEntry) {
        list.add(entry)
        entry.liveConsumer?.updateMemoryLimit(.default)
    }

    func register(_ consumer: Consumer, name: String) -> MemoryConsumerRegistration {
        MemoryConsumerRegistration(name: name, traits: traits, consumer: consumer, registry: self)
    }

    private let traits = MemoryConsumerTraits(
        estimatedUsage: .small, dataAccess: .none, retention: .lossless, recreateCost: .cheap,
        releaseCPUCost: .low, isStateful: true, supportsMemoryLimit: true)
}
