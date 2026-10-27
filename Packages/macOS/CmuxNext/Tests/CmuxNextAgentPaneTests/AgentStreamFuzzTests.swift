import CmuxFuzzSupport
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Seeded fuzz of the agent pane's daemon stream (plans/cmux-next/chrome-parity/p10-stability.md, task 179):
/// acpmux's frames into the relay (``AcpmuxRequestIds/toPage(_:)``), the observers that read the same parse
/// (``AcpmuxPaneSessions``, ``AcpmuxPermissionOptions``, ``AcpmuxDecisionContexts``), a real
/// ``AcpmuxPaneSocket`` on a wire, and the first-line reader (``AgentPaneLineReader``). Event lines, cut and
/// garbage frames, fields of the wrong type, huge strings, duplicate keys, and replies in any order: late,
/// twice, to cancelled or unknown ids. Chrome fuzzes the same layer: mojo/core/channel_fuzzer.cc feeds raw
/// bytes to a channel, and mojo/public/tools/fuzzers/mojolpm interleaves messages on live pipes.
///
/// The properties: no frame traps; each frame is dropped (and counted by ``AcpmuxRequestIds/droppedFrames``),
/// sent to the page as clean JSON under the page's own id, or closes the socket for two equal keys only;
/// the socket stays open through every other bad frame and delivers the rest in order; and the observers
/// end where a model written from their doc comments ends (``AgentStreamModel``).
///
/// It runs only with `CMUX_AGENT_STREAM_FUZZ=1`; agents run it on the fleet, CI does not (Lawrence 2026-10-23):
///
/// ```
/// CMUX_AGENT_STREAM_FUZZ=1 swift test --filter AgentStreamFuzzTests
/// CMUX_AGENT_STREAM_FUZZ=1 CMUX_FUZZ_DEADLINE=$(( $(date +%s) + 300 )) swift test --filter AgentStreamFuzzTests
/// ```
///
/// `CMUX_FUZZ_SEED` and `CMUX_FUZZ_ITERATIONS` replay a failure; with `CMUX_FUZZ_ARTIFACTS` set a trap leaves
/// its case behind (`AgentStream.<run>.inflight`). The suite is serialized, so `CMUX_FUZZ_DEADLINE` is split
/// equally between its ``runCount`` runs.
@Suite(
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["CMUX_AGENT_STREAM_FUZZ"] == "1",
        "set CMUX_AGENT_STREAM_FUZZ=1; agents run it on the fleet (Lawrence 2026-10-23)"
    )
)
struct AgentStreamFuzzTests {
    /// Two minutes past a long run's budget, so the limit stops a hang and never a long run.
    nonisolated static let timeLimitMinutes: Int = {
        let budget = (try? FuzzEnvironment.current())?.longModeBudget(from: Date()) ?? 0
        return 2 + Int((budget / 60).rounded(.up))
    }()

    /// The suite's runs (its `@Test`s), which share a `CMUX_FUZZ_DEADLINE`.
    nonisolated static let runCount = 6

    /// Each run's share of `CMUX_FUZZ_DEADLINE`, fixed when the first run asks; nil without a deadline or in a replay.
    nonisolated static let deadlineShare: TimeInterval? = {
        guard let environment = try? FuzzEnvironment.current(), environment.iterations == nil,
              let deadline = environment.deadline else { return nil }
        return max(deadline.timeIntervalSinceNow, 0) / Double(runCount)
    }()

    /// A run of this suite: the process's `CMUX_FUZZ_*` variables, its long mode capped at ``deadlineShare``.
    nonisolated static func run(_ name: String, seed: UInt64, iterations: Int) throws(FuzzError) -> FuzzRun {
        var environment = try FuzzEnvironment.current()
        if let share = deadlineShare { environment.seconds = min(environment.seconds ?? share, share) }
        return FuzzRun(name, seed: seed, iterations: iterations, environment: environment)
    }

    /// One input of the in-process checks, its choices read from `data` (the libFuzzer entry, p10-stability-182;
    /// CmuxNextAgentPane imports AppKit, so the Linux wrappers skip it). The socket and line-reader runs need
    /// queues and a pipe, so they are not part of it.
    nonisolated static func oneInput(_ data: Data) throws {
        var rng = FuzzRNG(replaying: data)
        switch rng.below(2) {
        case 0: try AgentStreamCase.stream(&rng)
        default: try AgentStreamCase.mutated(rng.bytes(4096))
        }
    }

    @Test(.timeLimit(.minutes(AgentStreamFuzzTests.timeLimitMinutes)))
    func oneInputTakesAnyBytes() throws {
        let run = try Self.run("AgentStream.oneInput", seed: 0xA6E7_0179_0001, iterations: 2_000)
        let seeds = [Data(), Data([0]), Data([0, 9, 3, 1, 7]), Data([1, 0x7B, 0x22]), Data(repeating: 0x5A, count: 64)]
        try run.forEachInput(try run.corpus(seeds: seeds)) { try Self.oneInput($0) }
    }

    /// Begins, cancels and frames in any order through one relay: each frame gets the outcome its kind
    /// names, the relay counts every drop, and sessions, folders, accepted prompts, decision contexts and
    /// deny options end where the model ends.
    @Test(.timeLimit(.minutes(AgentStreamFuzzTests.timeLimitMinutes)))
    func streamFramesKeepTheRelayContract() throws {
        try Self.run("AgentStream.stream", seed: 0xA6E7_0179_0002, iterations: 4_000).forEach { rng in
            try AgentStreamCase.stream(&rng)
        }
    }

    /// Byte and token mutations of real frames: dropped and counted, closed for a duplicate key only, or
    /// clean JSON under an id the page sent; the observers read whatever reaches the page.
    @Test(.timeLimit(.minutes(AgentStreamFuzzTests.timeLimitMinutes)))
    func mutatedFramesNeverTrap() throws {
        let run = try Self.run("AgentStream.mutated", seed: 0xA6E7_0179_0003, iterations: 8_000)
        let mutator = FuzzMutator(dictionary: AgentStreamFrames.tokens, maximumCount: 16_384)
        try run.forEachInput(try run.corpus(seeds: AgentStreamCase.seeds()), mutator: mutator) { try AgentStreamCase.mutated($0) }
    }

    /// A real socket on a wire reads a stream with bad frames among good ones: it stays open, the page gets
    /// every good frame in order and the sentinel after them, and every bad one is counted.
    @Test(.timeLimit(.minutes(AgentStreamFuzzTests.timeLimitMinutes)))
    func socketStaysLiveThroughBadFrames() async throws {
        try await Self.run("AgentStream.socket", seed: 0xA6E7_0179_0004, iterations: 300).forEachAwaiting { rng in
            try await AgentStreamCase.socketStaysLive(&rng)
        }
    }

    /// Two equal keys close the socket with `duplicateKey`, after at most the frames before them.
    @Test(.timeLimit(.minutes(AgentStreamFuzzTests.timeLimitMinutes)))
    func duplicateKeyClosesTheSocket() async throws {
        try await Self.run("AgentStream.duplicate", seed: 0xA6E7_0179_0005, iterations: 200).forEachAwaiting { rng in
            try await AgentStreamCase.duplicateKeyCloses(&rng)
        }
    }

    /// Any chunking of any bytes gives the first line, `lineTooLong` or `endOfFile`, as the reader says.
    @Test(.timeLimit(.minutes(AgentStreamFuzzTests.timeLimitMinutes)))
    func firstLineOfAnyChunks() async throws {
        try await Self.run("AgentStream.firstLine", seed: 0xA6E7_0179_0006, iterations: 1_000).forEachAwaiting { rng in
            try await AgentStreamCase.firstLine(&rng)
        }
    }
}

/// The relay counts each daemon frame it drops (p10-stability-179), without `CMUX_AGENT_STREAM_FUZZ`.
struct AgentStreamDropCountTests {
    @Test func droppedFramesAreCountedAndTheRestGoOn() {
        let ids = AcpmuxRequestIds()
        let relayID = ids.begin(pageID: "7", method: "session/new")
        #expect(relayID == 1)
        for text in ["", "{", "[]", #"{"jsonrpc":"2.0","id":9,"result":{}}"#, #"{"jsonrpc":"2.0","id":"1","result":{}}"#] {
            guard case .drop = ids.toPage(text) else {
                Issue.record("\(text) was not dropped")
                continue
            }
        }
        #expect(ids.droppedFrames == 5)
        guard case .page(let fresh, _, let method) = ids.toPage(#"{"jsonrpc":"2.0","id":1,"result":{"sessionId":"s"}}"#) else {
            Issue.record("the reply to the open request did not reach the page")
            return
        }
        #expect(method == "session/new" && fresh.contains(#""id":7"#))
        guard case .close = ids.toPage(#"{"jsonrpc":"2.0","method":"a","method":"b"}"#) else {
            Issue.record("a duplicate key did not close")
            return
        }
        #expect(ids.droppedFrames == 5)
    }
}
