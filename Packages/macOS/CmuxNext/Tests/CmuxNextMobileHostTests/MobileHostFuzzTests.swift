import CmuxFuzzSupport
import CmuxNextMobile
@testable import CmuxNextMobileHost
import Foundation
import Testing

/// Seeded fuzz of what phones send this Mac (plans/cmux-next/chrome-parity/p10-stability.md, task 027): the
/// shipped-iOS RPC frames on each phone's control stream (``MobileSyncFrameCodec`` frames read by
/// `MobileControlStream`, the loop `MobileIrxConnectionServer` runs per admitted phone, each answered by
/// that phone's ``MobileCompatSession``), the status lines `cmux-mobile-host` passes on from phones
/// (``MobileHostEvent``: links, paths, pair requests with the phone's own name and keys), the per-phone
/// state built from those lines (``MobileHostState``, and ``MobileHostPairing``, which `IPhoneHostService`
/// asks for every pairing decision) and the files a phone's pairing leaves (the paired list, the test
/// seed). Chrome treats every renderer the same way: mojo/core/channel_fuzzer.cc and ipc/ipc_message_fuzzer
/// feed any bytes to the browser's side of the pipe, and a bad message ends only that renderer
/// (content/browser/bad_message.cc, ReceivedBadMessage).
///
/// The properties: any frame gets one well-formed answer with its request's id; a frame past the codec's
/// limit ends that phone's stream and closes its session, while another phone's stream answers every
/// request in order and keeps its events (a bad frame closes only that peer); any line gives an event or
/// nothing, never a trap; a line about one phone changes only that phone's link, prompt and pairing; a
/// pairing flood stays bounded.
///
/// It runs only with `CMUX_MOBILE_HOST_FUZZ=1`; agents run it on the fleet, CI does not (Lawrence 2026-10-23):
///
/// ```
/// CMUX_MOBILE_HOST_FUZZ=1 swift test --filter MobileHostFuzzTests
/// CMUX_MOBILE_HOST_FUZZ=1 CMUX_FUZZ_DEADLINE=$(( $(date +%s) + 300 )) swift test --filter MobileHostFuzzTests
/// ```
///
/// `CMUX_FUZZ_SEED` and `CMUX_FUZZ_ITERATIONS` replay a failure; `CMUX_FUZZ_DEADLINE` is shared out
/// equally between the suite's ``runCount`` runs (it is serialized).
@Suite(
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["CMUX_MOBILE_HOST_FUZZ"] == "1",
        "set CMUX_MOBILE_HOST_FUZZ=1; agents run it on the fleet (Lawrence 2026-10-23)"
    )
)
nonisolated struct MobileHostFuzzTests {
    /// Two minutes past a long run's budget, so the limit stops a hang and never a long run.
    static let timeLimitMinutes: Int = {
        let budget = (try? FuzzEnvironment.current())?.longModeBudget(from: Date()) ?? 0
        return 2 + Int((budget / 60).rounded(.up))
    }()

    /// The suite's runs (one per `@Test`, two in the RPC and session-frame ones), which share a `CMUX_FUZZ_DEADLINE`.
    static let runCount = 11

    /// Each run's share of `CMUX_FUZZ_DEADLINE`, fixed when the first run asks; nil without a deadline or in a replay.
    static let deadlineShare: TimeInterval? = {
        guard let environment = try? FuzzEnvironment.current(), environment.iterations == nil,
              let deadline = environment.deadline else { return nil }
        return max(deadline.timeIntervalSinceNow, 0) / Double(runCount)
    }()

    static func run(_ name: String, seed: UInt64, iterations: Int) throws(FuzzError) -> FuzzRun {
        var environment = try FuzzEnvironment.current()
        if let share = deadlineShare { environment.seconds = min(environment.seconds ?? share, share) }
        return FuzzRun(name, seed: seed, iterations: iterations, environment: environment)
    }

    /// One input, its choices read from `data` (the libFuzzer entry). The stored-file
    /// run writes files and the session and stream runs await actors, so they are not part of it.
    static func oneInput(_ data: Data) throws {
        var rng = FuzzRNG(replaying: data)
        switch rng.below(5) {
        case 0: try HostLineSample(&rng).check()
        case 1: try HostRawLine.check(rng.bytes(512))
        case 2: try HostPhonesCase(&rng).check()
        case 3: try HostPairingCase(&rng).check()
        default: try HostRPCSample(&rng).check()
        }
    }

    @Test(.timeLimit(.minutes(MobileHostFuzzTests.timeLimitMinutes)))
    func oneInputTakesAnyBytes() throws {
        let run = try Self.run("MobileHost.oneInput", seed: 0x40B1_0027_0001, iterations: 3_000)
        let seeds = [Data(), Data([0]), Data([1, 4]), Data([2, 3, 1, 1]), Data([3, 2, 0, 0, 7]), Data([4])]
        try run.forEachInput(try run.corpus(seeds: seeds)) { try Self.oneInput($0) }
    }

    /// A well-formed status line decodes to its event; one missing a field its event needs, or with
    /// any field of the wrong type, decodes to nothing.
    @Test(.timeLimit(.minutes(MobileHostFuzzTests.timeLimitMinutes)))
    func statusLinesDecodeToTheirEventOrNothing() throws {
        try Self.run("MobileHost.line", seed: 0x40B1_0027_0002, iterations: 20_000).forEach { rng in
            try HostLineSample(&rng).check()
        }
    }

    /// Raw and mutated stdout lines (JSON-token mutations of real ones), read as the supervisor reads
    /// them, never trap the decoder or the state they fold into.
    @Test(.timeLimit(.minutes(MobileHostFuzzTests.timeLimitMinutes)))
    func rawLinesNeverTrapTheDecoder() throws {
        let run = try Self.run("MobileHost.rawLine", seed: 0x40B1_0027_0003, iterations: 10_000)
        let mutator = FuzzMutator(dictionary: FuzzJSON.tokens + HostRawLine.tokens, maximumCount: 8_192)
        try run.forEachInput(try run.corpus(seeds: HostRawLine.seeds), mutator: mutator) { line in
            try HostRawLine.check(line)
        }
    }

    /// Several phones' links with damaged and mutated lines between them: the state follows each
    /// phone's own lines, and a line that does not decode (or names one phone) leaves every other
    /// phone's link as it was.
    @Test(.timeLimit(.minutes(MobileHostFuzzTests.timeLimitMinutes)))
    func linkLinesChangeOnlyTheirPhone() throws {
        try Self.run("MobileHost.phones", seed: 0x40B1_0027_0004, iterations: 3_000).forEach { rng in
            try HostPhonesCase(&rng).check()
        }
    }

    /// Pair requests from several phones (good, damaged, flooding, with any keys and names, seeded), the
    /// person's answers, sign-outs, removals and connections turned off, through ``MobileHostPairing``:
    /// each step does what its contract says, at most ``MobileHostPairPrompts/limit`` wait, one each, and a
    /// step for one phone changes only that phone's prompt and pairing.
    @Test(.timeLimit(.minutes(MobileHostFuzzTests.timeLimitMinutes)))
    func pairRequestsChangeOnlyTheirPhone() throws {
        try Self.run("MobileHost.pairing", seed: 0x40B1_0027_0005, iterations: 3_000).forEach { rng in
            try HostPairingCase(&rng).check()
        }
    }

    /// Shipped-iOS RPC frames: a request object decodes with its method and parameters, anything else to
    /// nothing; mutated frames never trap.
    @Test(.timeLimit(.minutes(MobileHostFuzzTests.timeLimitMinutes)))
    func rpcFramesDecodeToTheirRequestOrNothing() throws {
        let run = try Self.run("MobileHost.rpc", seed: 0x40B1_0027_0006, iterations: 10_000)
        try run.forEach { rng in try HostRPCSample(&rng).check() }
        let mutator = FuzzMutator(dictionary: FuzzJSON.tokens + HostRPCSample.tokens, maximumCount: 8_192)
        let mutatedRun = try Self.run("MobileHost.rpcRaw", seed: 0x40B1_0027_0007, iterations: 10_000)
        try mutatedRun.forEachInput(try mutatedRun.corpus(seeds: HostRPCSample.seeds), mutator: mutator) { frame in
            try HostRPCSample.checkRaw(frame)
        }
    }

    /// Phone frames straight to a phone's session: a generated request gets the answer its contract names,
    /// with its id; any other bytes (mutated requests, garbage) get one well-formed answer, never a trap.
    @Test(.timeLimit(.minutes(MobileHostFuzzTests.timeLimitMinutes)))
    func sessionFramesGetOneWellFormedAnswer() async throws {
        let run = try Self.run("MobileHost.sessionFrame", seed: 0x40B1_0027_0009, iterations: 5_000)
        try await run.forEachAwaiting { rng in
            let request = try HostPhoneRequest(&rng)
            try await HostSessionFrame.check(request.payload, expected: request)
        }
        let mutatedRun = try Self.run("MobileHost.sessionFrameRaw", seed: 0x40B1_0027_000A, iterations: 5_000)
        let corpus = try mutatedRun.corpus(seeds: HostRPCSample.seeds)
        try await mutatedRun.forEachInputAwaiting(corpus, mutator: HostSessionFrame.mutator) { frame in
            try await HostSessionFrame.check(frame)
        }
    }

    /// Two phones' control streams at once, cut at random read boundaries: the fuzzed phone's good and
    /// mutated frames each get one answer in order, and a frame past the codec's limit ends only its stream
    /// and closes only its session; the other phone's requests all get their answers in order, and its
    /// session keeps its event stream.
    @Test(.timeLimit(.minutes(MobileHostFuzzTests.timeLimitMinutes)))
    func aBadFrameClosesOnlyThatPhone() async throws {
        try await Self.run("MobileHost.streams", seed: 0x40B1_0027_000B, iterations: 1_000).forEachAwaiting { rng in
            try await HostPhoneStreamsCase(&rng).check()
        }
    }

    /// The paired-phones file and the test seed file, saved, cut off and damaged on disk: a saved list loads
    /// as stored for its user and empty for any other, a cut-off one loads empty, a damaged one never loads
    /// another user's list; a seed that names the phone trusts it and one that names another phone does not.
    @Test(.timeLimit(.minutes(MobileHostFuzzTests.timeLimitMinutes)))
    func damagedPairingFilesLoadAsStoredOrEmpty() throws {
        let run = try Self.run("MobileHost.files", seed: 0x40B1_0027_0008, iterations: 1_000)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-host-fuzz-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try run.forEach { rng in try HostFilesCase(&rng).check(in: directory) }
    }
}
