import CryptoKit
import Darwin
import Foundation
import Testing

@testable import CMUXAgentLaunch

@Suite("Codex resume trust probe cache")
struct CodexResumeTrustProbeCacheTests {
    @Test("Does not reuse successful probes across sequential invocations")
    func doesNotCacheSuccessfulProbesAcrossInvocations() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CodexResumeTrustProbeCache(
            directory: directory,
            fileManager: .default
        )
        var probeCount = 0

        let first = cache.resolve(keyComponents: ["codex", "one"]) {
            probeCount += 1
            return ["/project"]
        }
        let second = cache.resolve(keyComponents: ["codex", "one"]) {
            probeCount += 1
            return ["/updated"]
        }

        #expect(first == ["/project"])
        #expect(second == ["/updated"])
        #expect(probeCount == 2)
    }

    @Test("Does not reuse failed probes across sequential invocations")
    func doesNotCacheFailedProbesAcrossInvocations() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CodexResumeTrustProbeCache(
            directory: directory,
            fileManager: .default
        )
        var probeCount = 0

        let first: Set<String>? = cache.resolve(keyComponents: ["failure"]) {
            probeCount += 1
            return nil
        }
        let second: Set<String>? = cache.resolve(keyComponents: ["failure"]) {
            probeCount += 1
            return ["/updated"]
        }

        #expect(first == nil)
        #expect(second == ["/updated"])
        #expect(probeCount == 2)
    }

    @Test("A stuck probe owner cannot block a waiter indefinitely")
    func stuckOwnerHasBoundedWait() throws {
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

        let released = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            Darwin.usleep(3_000_000)
            _ = flock(ownerFD, LOCK_UN)
            Darwin.close(ownerFD)
            released.signal()
        }

        var probeCount = 0
        let startedAt = Date()
        let result = CodexResumeTrustProbeCache(
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
        #expect(released.wait(timeout: .now() + 2) == .success)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-codex-probe-\(UUID().uuidString)",
                isDirectory: true
            )
    }
}
