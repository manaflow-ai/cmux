import CmuxNextActions
import CmuxNextCompat
@testable import CmuxNextControl
import CmuxNextSettings
import Testing

/// The idempotency cache as a memory consumer: the coordinator's limit scales how
/// many finished runs it keeps, a release drops the oldest finished ones, the newest
/// ``ControlIdempotencyCache/workingSet`` stay at any limit (their retries are still coming), and a
/// run still in flight is never dropped (its retry must join it, not run again).
struct ControlIdempotencyMemoryTests {
    private static let workingSet = ControlIdempotencyCache.workingSet

    private static func request(_ key: String) -> ControlIdempotencyCache.Fingerprint {
        .run(ControlActionRequest(actionID: "noop", arguments: ["key": .string(key)]))
    }

    private static func keys(_ range: Range<Int>) -> [String] {
        range.map { "k\($0)" }
    }

    /// Claims and finishes `keys` in order.
    private static func finish(_ keys: [String], in cache: ControlIdempotencyCache) {
        for key in keys {
            guard case .run = cache.claim(key, fingerprint: request(key)) else {
                Issue.record("\(key) did not run")
                continue
            }
            cache.finish(key, with: .success(.string(key)))
        }
    }

    @Test func aReleaseDropsTheOldestFinishedRunsDownToTheLimit() async {
        let cache = ControlIdempotencyCache(limit: 4 * Self.workingSet)
        Self.finish(Self.keys(0..<(4 * Self.workingSet)), in: cache)

        let usage = await cache.releaseMemory(downTo: MemoryLimit(percent: 50))

        #expect(cache.count == 2 * Self.workingSet)
        #expect(usage?.entries == 2 * Self.workingSet)
        #expect((usage?.footprintBytes ?? 0) > 0)
        #expect(!cache.hasOutcome("k0"))
        #expect(cache.hasOutcome("k\(4 * Self.workingSet - 1)"))
    }

    @Test func atLimitZeroOnlyTheWorkingSetStaysAndItsRetriesStillReplay() async {
        let cache = ControlIdempotencyCache(limit: 4 * Self.workingSet)
        Self.finish(Self.keys(0..<(2 * Self.workingSet)), in: cache)

        _ = await cache.updateMemoryLimit(.criticalThreshold)
        let usage = await cache.releaseMemory(downTo: .criticalThreshold)
        #expect(cache.count == Self.workingSet)
        #expect(usage?.entries == Self.workingSet)

        // The newest run's retry replays its reply, it does not run the action again.
        let newest = "k\(2 * Self.workingSet - 1)"
        guard case .finished(.success(.string(newest))) = cache.claim(newest, fingerprint: Self.request(newest)) else {
            Issue.record("a retry of a run in the working set must replay it")
            return
        }
        // An older released key runs again, as one evicted by later runs does.
        guard case .run = cache.claim("k0", fingerprint: Self.request("k0")) else {
            Issue.record("a released key must run again")
            return
        }
    }

    @Test func aRunInFlightIsNeverReleased() async {
        let cache = ControlIdempotencyCache(limit: 4 * Self.workingSet)
        guard case .run = cache.claim("live", fingerprint: Self.request("live")) else {
            Issue.record("live did not run")
            return
        }
        Self.finish(Self.keys(0..<(2 * Self.workingSet)), in: cache)

        _ = await cache.releaseMemory(downTo: .criticalThreshold)

        #expect(cache.count == Self.workingSet)
        guard case .join = cache.claim("live", fingerprint: Self.request("live")) else {
            Issue.record("a retry of the run in flight must join it")
            return
        }
    }

    @Test func theLimitBoundsNewRunsAndTheFullLimitKeepsTheConfiguredBound() async {
        let cache = ControlIdempotencyCache(limit: 4 * Self.workingSet)
        _ = await cache.updateMemoryLimit(MemoryLimit(percent: 50))
        Self.finish(Self.keys(0..<(3 * Self.workingSet)), in: cache)
        #expect(cache.count == 2 * Self.workingSet)

        _ = await cache.updateMemoryLimit(.default)
        Self.finish(Self.keys((3 * Self.workingSet)..<(6 * Self.workingSet)), in: cache)
        #expect(cache.count == 4 * Self.workingSet)
    }

    /// A registry that hands each new consumer the default limit at once, as the coordinator does.
    @MainActor private final class FakeRegistry: MemoryConsumerRegistry {
        var entries: [MemoryConsumerEntry] = []

        func addMemoryConsumer(_ entry: MemoryConsumerEntry) {
            entries.append(entry)
            entry.liveConsumer?.updateMemoryLimit(.default)
        }
    }

    @MainActor @Test func aServiceRegistersItsCacheWhileItLives() throws {
        let registry = FakeRegistry()
        var service: ControlService? = try ControlService.prepare(
            registry: ActionRegistry(catalog: []), settingsStore: nil,
            configuration: .init(path: temporarySocketPath(), accessMode: .automation), identity: testIdentity())
        #expect(registry.entries.isEmpty)

        service?.registerMemoryConsumer(with: registry, hop: AsyncMemoryConsumerHop { _ in })

        #expect(registry.entries.map(\.name) == ["control-idempotency"])
        #expect(registry.entries.first?.traits == ControlIdempotencyCache.memoryTraits)
        #expect(registry.entries.first?.isLive == true)

        service?.stop()
        service = nil
        #expect(registry.entries.first?.isLive == false, "a gone service leaves the coordinator")
    }

    /// The report reads a counter the cache keeps: each finished reply's size is counted once, and an
    /// eviction, a release or a forgotten run takes its share back out.
    @Test func theUsageIsTheRunningSumOfTheKeptReplies() async {
        let cache = ControlIdempotencyCache(limit: 2 * Self.workingSet)
        let keys = Self.keys(0..<(3 * Self.workingSet))
        Self.finish(keys, in: cache)
        let each = ControlIdempotencyCache.estimatedBytes(of: .string("k10"))
        #expect(each == JSONValue.string("k10").compactText.utf8.count, "the estimate is exact for an escape-free reply")

        let full = await cache.updateMemoryLimit(.default)
        let kept = keys.suffix(2 * Self.workingSet)
        #expect(full == MemoryUsage(footprintBytes: kept.reduce(0) { $0 + ControlIdempotencyCache.estimatedBytes(of: .string($1)) },
                                    entries: kept.count), "an eviction left its reply's bytes in the count")

        let released = await cache.releaseMemory(downTo: .criticalThreshold)
        let working = keys.suffix(Self.workingSet)
        #expect(released == MemoryUsage(footprintBytes: working.reduce(0) { $0 + ControlIdempotencyCache.estimatedBytes(of: .string($1)) },
                                        entries: working.count))

        guard case .run = cache.claim("live", fingerprint: Self.request("live")) else {
            Issue.record("live did not run")
            return
        }
        cache.forget("live")
        #expect(await cache.updateMemoryLimit(.criticalThreshold) == released, "a forgotten run changed the count")
    }

    @Test func theEstimateCountsNestedRepliesWithoutWritingThem() {
        let reply = JSONValue.object([
            "ok": .bool(true), "items": .array([.string("a"), .null, .object([:]), .array([])]), "n": .number(12),
        ])
        // Exact but for the number, estimated at 8 bytes ("12" is 2).
        #expect(ControlIdempotencyCache.estimatedBytes(of: reply) == reply.compactText.utf8.count + 6)
    }

    @Test func aCacheSmallerThanTheWorkingSetKeepsItsOwnBound() async {
        let cache = ControlIdempotencyCache(limit: 4)
        Self.finish(["a", "b", "c", "d"], in: cache)

        _ = await cache.releaseMemory(downTo: .criticalThreshold)

        #expect(cache.count == 4)
    }
}
