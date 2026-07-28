import CryptoKit
import Darwin
import Foundation
import Testing

@testable import CMUXAgentLaunch

@Suite("Codex resume trust probe cache")
struct CodexResumeTrustProbeCacheTests {
    @Test("Does not reuse successful probes across sequential invocations")
    func doesNotCacheSuccessfulProbesAcrossInvocations() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CodexResumeTrustProbeCache(
            directory: directory,
            fileManager: .default
        )
        var probeCount = 0

        let first = await cache.resolve(keyComponents: ["codex", "one"]) {
            probeCount += 1
            return ["/project"]
        }
        let second = await cache.resolve(keyComponents: ["codex", "one"]) {
            probeCount += 1
            return ["/updated"]
        }

        #expect(first == ["/project"])
        #expect(second == ["/updated"])
        #expect(probeCount == 2)
    }

    @Test("Does not reuse failed probes across sequential invocations")
    func doesNotCacheFailedProbesAcrossInvocations() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CodexResumeTrustProbeCache(
            directory: directory,
            fileManager: .default
        )
        var probeCount = 0

        let first: Set<String>? = await cache.resolve(keyComponents: ["failure"]) {
            probeCount += 1
            return nil
        }
        let second: Set<String>? = await cache.resolve(keyComponents: ["failure"]) {
            probeCount += 1
            return ["/updated"]
        }

        #expect(first == nil)
        #expect(second == ["/updated"])
        #expect(probeCount == 2)
    }

    @Test("A stuck probe owner fails closed without a fallback probe")
    func stuckOwnerHasBoundedWait() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let keyComponents = ["codex", "stuck-owner"]
        let key = SHA256.hash(
            data: Data(keyComponents.joined(separator: "\u{0}").utf8)
        ).map { String(format: "%02x", $0) }.joined()
        let shard = Int(key.prefix(2), radix: 16) ?? 0
        let lockURL = directory.appendingPathComponent(
            String(format: "lock-%03d-of-256", shard),
            isDirectory: false
        )
        let ownerFD = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        #expect(ownerFD >= 0)
        guard ownerFD >= 0 else { return }
        #expect(flock(ownerFD, LOCK_EX | LOCK_NB) == 0)

        defer {
            _ = flock(ownerFD, LOCK_UN)
            Darwin.close(ownerFD)
        }

        let outcome = try await expectCompletes(within: 2) {
            var probeCount = 0
            let result = await CodexResumeTrustProbeCache(
                directory: directory,
                fileManager: .default,
                keyWait: .milliseconds(200),
                probeSlotWait: .milliseconds(200)
            ).resolve(
                keyComponents: keyComponents
            ) {
                probeCount += 1
                return ["/fallback"]
            }
            return (result, probeCount)
        }

        #expect(outcome.0 == nil)
        #expect(outcome.1 == 0)
    }

    @Test("Timed-out same-key waiters never start independent probes")
    func sameKeyTimeoutDoesNotCreateProbeHerd() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let activity = ProbeActivity()
        let ownerStarted = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let releaseOwner = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let owner = Task {
            await CodexResumeTrustProbeCache(
                directory: directory,
                fileManager: .default,
                keyWait: .seconds(1),
                probeSlotWait: .seconds(1)
            ).resolve(keyComponents: ["same-key"]) {
                await activity.enter()
                _ = ownerStarted.continuation.yield()
                ownerStarted.continuation.finish()
                var releases = releaseOwner.stream.makeAsyncIterator()
                _ = await releases.next()
                await activity.leave()
                return Set(["/owner"])
            }
        }
        defer { owner.cancel() }

        var starts = ownerStarted.stream.makeAsyncIterator()
        let didStart: Void? = await starts.next()
        #expect(didStart != nil)

        let waiters = (0..<8).map { _ in
            Task {
                await CodexResumeTrustProbeCache(
                    directory: directory,
                    fileManager: .default,
                    keyWait: .milliseconds(150),
                    probeSlotWait: .seconds(1)
                ).resolve(keyComponents: ["same-key"]) {
                    await activity.enter()
                    await activity.leave()
                    return Set(["/duplicate"])
                }
            }
        }
        let waiterResults = try await expectCompletes(within: 2) {
            var values: [Set<String>?] = []
            for waiter in waiters {
                values.append(await waiter.value)
            }
            return values
        }
        #expect(waiterResults.allSatisfy { $0 == nil })
        #expect(await activity.totalStarts == 1)

        _ = releaseOwner.continuation.yield()
        releaseOwner.continuation.finish()
        #expect(try await expectCompletes(within: 2) { await owner.value } == ["/owner"])
    }

    @Test("Different keys share a small process-wide probe cap")
    func differentKeysRespectProbeConcurrencyCap() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let activity = ProbeActivity()

        let tasks = (0..<8).map { index in
            Task {
                await CodexResumeTrustProbeCache(
                    directory: directory,
                    fileManager: .default,
                    keyWait: .seconds(2),
                    probeSlotWait: .seconds(2),
                    probeSlotCount: 2
                ).resolve(keyComponents: ["different-key", String(index)]) {
                    await activity.enter()
                    try? await Task.sleep(for: .milliseconds(100))
                    await activity.leave()
                    return Set(["/\(index)"])
                }
            }
        }
        let results = try await expectCompletes(within: 3) {
            var values: [Set<String>?] = []
            for task in tasks {
                values.append(await task.value)
            }
            return values
        }

        #expect(results.compactMap { $0 }.count == 8)
        #expect(await activity.maximumActive == 2)
        #expect(await activity.totalStarts == 8)
    }

    @Test("Different keys sharing a shard retry immediately after release")
    func shardCollisionRetriesAfterOwnerRelease() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = collidingKeyComponents()
        let ownerStarted = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let releaseOwner = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let waiterContended = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )

        let ownerCache = CodexResumeTrustProbeCache(
            directory: directory,
            fileManager: .default
        )
        let ownerTask = Task {
            await ownerCache.resolve(
                keyComponents: keys.owner
            ) {
                _ = ownerStarted.continuation.yield()
                ownerStarted.continuation.finish()
                var releases = releaseOwner.stream.makeAsyncIterator()
                _ = await releases.next()
                return Set(["/owner"])
            }
        }
        defer { ownerTask.cancel() }

        var ownerStarts = ownerStarted.stream.makeAsyncIterator()
        let didStartOwner: Void? = await ownerStarts.next()
        #expect(didStartOwner != nil)

        let waiterCache = CodexResumeTrustProbeCache(
            directory: directory,
            fileManager: .default,
            contentionObserver: {
                _ = waiterContended.continuation.yield()
                waiterContended.continuation.finish()
            }
        )
        let waiterTask = Task {
            await waiterCache.resolve(
                keyComponents: keys.waiter
            ) {
                Set(["/waiter"])
            }
        }
        defer { waiterTask.cancel() }

        var contentions = waiterContended.stream.makeAsyncIterator()
        let didContend: Void? = await contentions.next()
        #expect(didContend != nil)

        _ = releaseOwner.continuation.yield()
        releaseOwner.continuation.finish()
        let results = try await expectCompletes(within: 1.5) {
            await (ownerTask.value, waiterTask.value)
        }

        #expect(results.0 == ["/owner"])
        #expect(results.1 == ["/waiter"])
    }

    private func expectCompletes<Value: Sendable>(
        within seconds: Double,
        _ work: @Sendable @escaping () async -> Value,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw TimedOutWaiting()
            }
            do {
                guard let value = try await group.next() else {
                    throw TimedOutWaiting()
                }
                group.cancelAll()
                return value
            } catch is TimedOutWaiting {
                group.cancelAll()
                Issue.record(
                    "operation did not complete within \(seconds) seconds",
                    sourceLocation: sourceLocation
                )
                throw TimedOutWaiting()
            }
        }
    }

    private struct TimedOutWaiting: Error {}

    private actor ProbeActivity {
        private(set) var active = 0
        private(set) var maximumActive = 0
        private(set) var totalStarts = 0

        func enter() {
            active += 1
            totalStarts += 1
            maximumActive = max(maximumActive, active)
        }

        func leave() {
            active -= 1
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-codex-probe-\(UUID().uuidString)",
                isDirectory: true
            )
    }

    private func collidingKeyComponents() -> (
        owner: [String],
        waiter: [String]
    ) {
        var firstByShard: [UInt8: [String]] = [:]
        for index in 0...256 {
            let components = ["shard-collision", String(index)]
            let digest = SHA256.hash(
                data: Data(components.joined(separator: "\u{0}").utf8)
            )
            guard let shard = Array(digest).first else { continue }
            if let first = firstByShard[shard] {
                return (first, components)
            }
            firstByShard[shard] = components
        }
        fatalError("257 keys must contain a SHA-256 first-byte collision")
    }
}
