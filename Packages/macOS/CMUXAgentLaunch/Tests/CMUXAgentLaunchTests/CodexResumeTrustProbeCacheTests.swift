import Foundation
import Testing

@testable import CMUXAgentLaunch

@Suite("Codex resume trust probe cache")
struct CodexResumeTrustProbeCacheTests {
    @Test("Does not reuse successful probes across sequential invocations")
    func doesNotCacheSuccessfulProbesAcrossInvocations() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CodexResumeTrustProbeCache(directory: directory)
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
        let cache = CodexResumeTrustProbeCache(directory: directory)
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

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-codex-probe-\(UUID().uuidString)",
                isDirectory: true
            )
    }
}
