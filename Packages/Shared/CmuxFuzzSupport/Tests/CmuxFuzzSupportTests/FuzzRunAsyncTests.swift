@testable import CmuxFuzzSupport
import Foundation
import Testing

/// The awaiting runs choose the same generators and inputs as the synchronous ones, and fail
/// with the same replay line.
@Suite struct FuzzRunAsyncTests {
    @Test func anAwaitingRunDrawsWhatTheSynchronousRunDraws() async throws {
        let run = FuzzRun("Async.draws", seed: 0x51, iterations: 40, environment: FuzzEnvironment())
        var expected: [UInt64] = []
        try run.forEach { rng in expected.append(rng.next()) }
        var drawn: [UInt64] = []
        let count = try await run.forEachAwaiting { rng in
            await Task.yield()
            drawn.append(rng.next())
        }
        #expect(count == 40)
        #expect(drawn == expected)
    }

    @Test func anAwaitingInputRunVisitsTheSynchronousRunsInputs() async throws {
        let run = FuzzRun("Async.inputs", seed: 0x52, iterations: 64, environment: FuzzEnvironment())
        let corpus = FuzzCorpus(seeds: [Data("seed".utf8), Data([0, 1, 2])])
        var expected: [Data] = []
        try run.forEachInput(corpus) { expected.append($0) }
        var visited: [Data] = []
        let count = try await run.forEachInputAwaiting(corpus) { input in
            await Task.yield()
            visited.append(input)
        }
        #expect(count == 66)
        #expect(visited == expected)
    }

    @Test func anAwaitingFailureNamesItsIterationAndKeepsItsInput() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fuzz-async-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let run = FuzzRun("Async.fails", seed: 0x53, iterations: 20, environment: FuzzEnvironment(artifacts: root))
        let corpus = FuzzCorpus(seeds: [Data("a".utf8)])
        var index = 0
        do {
            try await run.forEachInputAwaiting(corpus) { _ in
                await Task.yield()
                defer { index += 1 }
                try FuzzRun.check(index < 5, "the sixth input")
            }
            Issue.record("the run did not fail")
        } catch let FuzzError.failed(failure) {
            // Input 0 is the corpus seed (iteration -1); input 5 is iteration 4.
            #expect(failure.iteration == 4)
            #expect(failure.replay.hasPrefix("CMUX_FUZZ_SEED=0x53 CMUX_FUZZ_ITERATIONS=5"))
            let artifact = try #require(failure.artifact)
            #expect(FileManager.default.fileExists(atPath: artifact.path))
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Async.fails.inflight").path))
        }
    }
}
