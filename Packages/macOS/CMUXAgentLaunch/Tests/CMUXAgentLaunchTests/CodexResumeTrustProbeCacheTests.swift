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

    @Test("A stuck probe owner cannot block a waiter indefinitely")
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

        var probeCount = 0
        let startedAt = Date()
        let result = await CodexResumeTrustProbeCache(
            directory: directory,
            fileManager: .default
        ).resolve(
            keyComponents: keyComponents
        ) {
            probeCount += 1
            return ["/fallback"]
        }
        let elapsed = Date().timeIntervalSince(startedAt)

        #expect(result == ["/fallback"])
        #expect(probeCount == 1)
        #expect(elapsed < 2.75, "waited \(elapsed) seconds")
    }

    @Test("Different keys sharing a shard retry immediately after release")
    func shardCollisionRetriesAfterOwnerRelease() async {
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
        async let ownerResult = ownerCache.resolve(
            keyComponents: keys.owner
        ) {
            _ = ownerStarted.continuation.yield()
            ownerStarted.continuation.finish()
            var releases = releaseOwner.stream.makeAsyncIterator()
            _ = await releases.next()
            return Set(["/owner"])
        }

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
        async let waiterResult = waiterCache.resolve(
            keyComponents: keys.waiter
        ) {
            Set(["/waiter"])
        }

        var contentions = waiterContended.stream.makeAsyncIterator()
        let didContend: Void? = await contentions.next()
        #expect(didContend != nil)

        let releasedAt = Date()
        _ = releaseOwner.continuation.yield()
        releaseOwner.continuation.finish()
        let results = await (ownerResult, waiterResult)
        let elapsed = Date().timeIntervalSince(releasedAt)

        #expect(results.0 == ["/owner"])
        #expect(results.1 == ["/waiter"])
        #expect(elapsed < 1.5, "waited \(elapsed) seconds")
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
