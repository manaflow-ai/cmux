import Foundation
import Testing

@testable import CmuxAgentChat

@Suite("AgentUsageSampler")
struct AgentUsageSamplerTests {
    private typealias Fixture = AgentUsageFixtures

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agent-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    @Test func readsIncrementallyAcrossPartialLines() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("s.jsonl")
        let first = Fixture.claudeAssistant(id: "msg_a", input: 10, cacheRead: 1000, output: 1)
        let second = Fixture.claudeAssistant(id: "msg_b", input: 20, cacheRead: 2000, output: 2)
        let splitIndex = second.index(second.startIndex, offsetBy: second.count / 2)
        try Data((first + "\n" + second[..<splitIndex]).utf8).write(to: url)
        // Tiny chunks exercise line reassembly across reads.
        let sampler = AgentUsageSampler(reader: AgentUsageTranscriptReader(chunkSize: 7))

        let initial = try #require(await sampler.sample(transcriptPath: url.path, source: .claude))
        #expect(initial.contextTokens == 1010)

        try append(String(second[splitIndex...]) + "\n", to: url)
        let updated = try #require(await sampler.sample(transcriptPath: url.path, source: .claude))
        #expect(updated.contextTokens == 2020)
    }

    @Test func rewriteInPlaceToALargerFileStartsOver() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("s.jsonl")
        let original = Fixture.claudeAssistant(id: "msg_a", input: 10, cacheRead: 90000, output: 9000)
        try Data((original + "\n").utf8).write(to: url)
        let sampler = AgentUsageSampler()
        let before = try #require(await sampler.sample(transcriptPath: url.path, source: .claude))

        // Same inode, larger size, different head: a truncate-and-rewrite.
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        let rewritten = [
            Fixture.claudeAssistant(id: "msg_x", model: "claude-haiku-4-5", input: 1, cacheRead: 5, output: 1),
            Fixture.claudeAssistant(id: "msg_y", model: "claude-haiku-4-5", input: 1, cacheRead: 7, output: 1),
        ].joined(separator: "\n") + "\n" + String(repeating: " ", count: 1000) + "\n"
        try handle.write(contentsOf: Data(rewritten.utf8))
        try handle.close()
        let after = try #require(await sampler.sample(transcriptPath: url.path, source: .claude))

        #expect(after.contextTokens == 8)
        #expect(after.modelDisplayName == "Haiku 4.5")
        #expect(try #require(after.estimatedCost).usd < (try #require(before.estimatedCost).usd))
    }

    @Test func largeFileIsReadFromItsTailWithoutACost() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("s.jsonl")
        let lines = (0..<50).map { index in
            Fixture.claudeAssistant(id: "msg_\(index)", input: 1, cacheRead: 1000 + index, output: 1)
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        let reader = AgentUsageTranscriptReader(fullScanLimit: 2000, tailBytes: 1500)
        let sampler = AgentUsageSampler(reader: reader)

        let snapshot = try #require(await sampler.sample(transcriptPath: url.path, source: .claude))
        #expect(snapshot.contextTokens == 1050)
        #expect(snapshot.estimatedCost == nil)
    }

    @Test func oversizedLineIsSkippedAndMarksCostPartial() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("s.jsonl")
        let huge = String(repeating: "x", count: 5000)
        let text = [
            Fixture.claudeAssistant(id: "msg_a", input: 1, cacheRead: 10, output: 1),
            huge,
            Fixture.claudeAssistant(id: "msg_b", input: 1, cacheRead: 20, output: 1),
        ].joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: url)
        let sampler = AgentUsageSampler(reader: AgentUsageTranscriptReader(chunkSize: 512, maxLineBytes: 1000))

        let snapshot = try #require(await sampler.sample(transcriptPath: url.path, source: .claude))
        #expect(snapshot.contextTokens == 21)
        #expect(try #require(snapshot.estimatedCost).isLowerBound)
    }

    @Test func claudeSubagentTranscriptsAddCostButNotContext() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session.jsonl")
        try Data((Fixture.claudeAssistant(id: "msg_a", input: 10, cacheRead: 40000, output: 20) + "\n").utf8).write(to: url)
        let subagents = directory.appendingPathComponent("session/subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        let sub = Fixture.claudeAssistant(
            id: "msg_sub", model: "claude-haiku-4-5-20251001", input: 100, cacheRead: 90000, output: 50, isSidechain: true
        )
        try Data((sub + "\n").utf8).write(to: subagents.appendingPathComponent("agent-a1.jsonl"))
        try Data("{}".utf8).write(to: subagents.appendingPathComponent("agent-a1.meta.json"))

        let snapshot = try #require(await AgentUsageSampler().sample(transcriptPath: url.path, source: .claude))
        #expect(snapshot.contextTokens == 40010)
        #expect(snapshot.modelDisplayName == "Opus 4.8")
        #expect(abs(try #require(snapshot.estimatedCost).usd - 0.0299) < 1e-9)
    }

    @Test func forgottenTranscriptStartsFromScratch() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("s.jsonl")
        try Data((Fixture.claudeAssistant(id: "msg_a", input: 1, cacheRead: 10, output: 1) + "\n").utf8).write(to: url)
        let sampler = AgentUsageSampler()
        _ = await sampler.sample(transcriptPath: url.path, source: .claude)
        await sampler.forget(transcriptPath: url.path)
        let again = try #require(await sampler.sample(transcriptPath: url.path, source: .claude))
        #expect(again.contextTokens == 11)
    }

    @Test func missingTranscriptYieldsNil() async {
        let sampler = AgentUsageSampler()
        #expect(await sampler.sample(transcriptPath: "/nonexistent/\(UUID().uuidString).jsonl", source: .codex) == nil)
    }
}
