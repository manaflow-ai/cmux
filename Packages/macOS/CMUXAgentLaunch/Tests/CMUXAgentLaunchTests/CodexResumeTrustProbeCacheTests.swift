import Foundation
import Testing

@testable import CMUXAgentLaunch

@Suite("Codex resume trust probe cache")
struct CodexResumeTrustProbeCacheTests {
    @Test("Caches successful probes by every key component")
    func cachesSuccessfulProbes() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CodexResumeTrustProbeCache(directory: directory)
        var probeCount = 0

        let first = cache.resolve(keyComponents: ["codex", "one"]) {
            probeCount += 1
            return ["/project"]
        }
        let cached = cache.resolve(keyComponents: ["codex", "one"]) {
            probeCount += 1
            return ["/unexpected"]
        }
        let otherKey = cache.resolve(keyComponents: ["codex", "two"]) {
            probeCount += 1
            return ["/other"]
        }

        #expect(first == ["/project"])
        #expect(cached == ["/project"])
        #expect(otherKey == ["/other"])
        #expect(probeCount == 2)
    }

    @Test("Caches fail-closed probes")
    func cachesFailedProbes() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CodexResumeTrustProbeCache(directory: directory)
        var probeCount = 0

        let first: Set<String>? = cache.resolve(keyComponents: ["failure"]) {
            probeCount += 1
            return nil
        }
        let cached: Set<String>? = cache.resolve(keyComponents: ["failure"]) {
            probeCount += 1
            return ["/unexpected"]
        }

        #expect(first == nil)
        #expect(cached == nil)
        #expect(probeCount == 1)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-codex-probe-\(UUID().uuidString)",
                isDirectory: true
            )
    }
}
