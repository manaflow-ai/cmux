import Foundation
import Testing

@testable import CmuxAgentChat

@Suite("AgentUsageSampler")
struct AgentUsageSamplerTests {
    private typealias Fixture = AgentUsageFixtures

    private func makeTranscriptURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-usage-\(UUID().uuidString).jsonl")
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    @Test func readsIncrementallyAcrossPartialLines() async throws {
        let url = makeTranscriptURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = Fixture.claudeAssistant(id: "msg_a", input: 10, cacheRead: 1000, output: 1)
        let second = Fixture.claudeAssistant(id: "msg_b", input: 20, cacheRead: 2000, output: 2)
        let splitIndex = second.index(second.startIndex, offsetBy: second.count / 2)
        try Data((first + "\n" + second[..<splitIndex]).utf8).write(to: url)
        // Tiny chunks exercise line reassembly across reads.
        let sampler = AgentUsageSampler(chunkSize: 7)

        let initial = try #require(await sampler.sample(transcriptPath: url.path, source: .claude))
        #expect(initial.contextTokens == 1010)

        try append(String(second[splitIndex...]) + "\n", to: url)
        let updated = try #require(await sampler.sample(transcriptPath: url.path, source: .claude))
        #expect(updated.contextTokens == 2020)
    }

    @Test func replacedTranscriptStartsOver() async throws {
        let url = makeTranscriptURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let big = Fixture.claudeAssistant(id: "msg_a", input: 10, cacheRead: 90000, output: 9000)
        try Data((big + "\n" + big.replacingOccurrences(of: "msg_a", with: "msg_b") + "\n").utf8).write(to: url)
        let sampler = AgentUsageSampler()
        let before = try #require(await sampler.sample(transcriptPath: url.path, source: .claude))

        let small = Fixture.claudeAssistant(id: "msg_c", input: 1, cacheRead: 5, output: 1)
        try Data((small + "\n").utf8).write(to: url, options: .atomic)
        let after = try #require(await sampler.sample(transcriptPath: url.path, source: .claude))

        #expect(after.contextTokens == 6)
        #expect(try #require(after.estimatedCostUSD) < (try #require(before.estimatedCostUSD)))
    }

    @Test func missingTranscriptYieldsNil() async {
        let sampler = AgentUsageSampler()
        #expect(await sampler.sample(transcriptPath: "/nonexistent/\(UUID().uuidString).jsonl", source: .codex) == nil)
    }
}
