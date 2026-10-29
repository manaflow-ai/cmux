import CmuxFuzzSupport
@testable import CmuxNextDevices
import Foundation
import Testing

/// Seeded fuzz of everything the device hub sends this device (plans/cmux-next/chrome-parity/p10-stability.md,
/// task 027): the User DO socket's push frames (``DeviceHubPush``), the records of its HTTP answers
/// (``HubDevice``, ``HubRelay`` and the rest, lenient by contract), the signed HTTP calls of
/// ``DeviceHubClient`` against any answer, the socket loop of ``DeviceHubSocket`` and the session state of
/// ``DeviceHub`` under a stream of good and damaged frames, and the crypto inputs another device controls
/// (signing keys, signatures, sealed relay blobs). Chrome fuzzes the same boundary: a renderer or a server
/// is untrusted, so mojo/core/channel_fuzzer.cc feeds raw bytes to the channel, and
/// components/cbor/reader_fuzzer.cc and crypto's signature_verifier fuzzers take any bytes.
///
/// The properties: any input gives a value or a typed error, never a trap; a frame that does not decode
/// changes nothing and does not end the socket (the hub is this device's only peer on it, so a bad frame
/// is dropped, not the connection); a push about one session, read through the socket into ``DeviceHub``,
/// changes only that session; every request is signed over exactly the route it goes to.
///
/// It runs only with `CMUX_DEVICE_HUB_FUZZ=1`; agents run it on the fleet, CI does not (Lawrence 2026-10-23):
///
/// ```
/// CMUX_DEVICE_HUB_FUZZ=1 swift test --filter DeviceHubFuzzTests
/// CMUX_DEVICE_HUB_FUZZ=1 CMUX_FUZZ_DEADLINE=$(( $(date +%s) + 300 )) swift test --filter DeviceHubFuzzTests
/// ```
///
/// `CMUX_FUZZ_SEED` and `CMUX_FUZZ_ITERATIONS` replay a failure; `CMUX_FUZZ_DEADLINE` is shared out
/// equally between the suite's ``runCount`` runs (it is serialized).
@Suite(
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["CMUX_DEVICE_HUB_FUZZ"] == "1",
        "set CMUX_DEVICE_HUB_FUZZ=1; agents run it on the fleet (Lawrence 2026-10-23)"
    )
)
struct DeviceHubFuzzTests {
    /// Two minutes past a long run's budget, so the limit stops a hang and never a long run.
    static let timeLimitMinutes: Int = {
        let budget = (try? FuzzEnvironment.current())?.longModeBudget(from: Date()) ?? 0
        return 2 + Int((budget / 60).rounded(.up))
    }()

    /// The suite's runs (its `@Test`s), which share a `CMUX_FUZZ_DEADLINE`.
    static let runCount = 7

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

    /// One input of the in-process checks, its choices read from `data` (the libFuzzer entry).
    /// The socket, HTTP and session runs need tasks and URLSession, so they are not part of it.
    static func oneInput(_ data: Data) throws {
        var rng = FuzzRNG(replaying: data)
        switch rng.below(4) {
        case 0: try HubPushSample(&rng).check()
        case 1: try HubRecordCase.check(&rng)
        case 2: try HubCryptoCase.check(&rng)
        default: try HubRawFrame.check(String(decoding: rng.bytes(512), as: UTF8.self))
        }
    }

    @Test(.timeLimit(.minutes(DeviceHubFuzzTests.timeLimitMinutes)))
    func oneInputTakesAnyBytes() throws {
        let run = try Self.run("DeviceHub.oneInput", seed: 0xDE71_0027_0001, iterations: 3_000)
        let seeds = [Data(), Data([0]), Data([1, 3]), Data([2, 9, 9]), Data([3]) + Data(#"{"type":"pong"}"#.utf8)]
        try run.forEachInput(try run.corpus(seeds: seeds)) { try Self.oneInput($0) }
    }

    /// A well-formed push decodes to its case, one missing or mistyping a field it needs to nothing,
    /// and lenient fields of a wrong type to their defaults.
    @Test(.timeLimit(.minutes(DeviceHubFuzzTests.timeLimitMinutes)))
    func pushFramesDecodeToTheirCaseOrNothing() throws {
        try Self.run("DeviceHub.push", seed: 0xDE71_0027_0002, iterations: 20_000).forEach { rng in
            try HubPushSample(&rng).check()
        }
    }

    /// Raw and mutated socket frames (JSON-token mutations of real pushes) never trap the decoder.
    @Test(.timeLimit(.minutes(DeviceHubFuzzTests.timeLimitMinutes)))
    func rawFramesNeverTrapTheDecoder() throws {
        let run = try Self.run("DeviceHub.rawFrame", seed: 0xDE71_0027_0003, iterations: 10_000)
        let mutator = FuzzMutator(dictionary: FuzzJSON.tokens + HubRawFrame.tokens, maximumCount: 8_192)
        try run.forEachInput(try run.corpus(seeds: HubRawFrame.seeds), mutator: mutator) { frame in
            try HubRawFrame.check(String(decoding: frame, as: UTF8.self))
        }
    }

    /// HTTP records with any value in any field: the required ids decide, every other field is lenient,
    /// and the keys, signatures and sealed blobs another device sends never trap.
    @Test(.timeLimit(.minutes(DeviceHubFuzzTests.timeLimitMinutes)))
    func recordsAndPeerCryptoTakeAnyValue() throws {
        try Self.run("DeviceHub.records", seed: 0xDE71_0027_0004, iterations: 5_000).forEach { rng in
            try HubRecordCase.check(&rng)
            try HubCryptoCase.check(&rng)
        }
    }

    /// A socket that reads good, damaged and mutated frames delivers every frame that decodes, in order,
    /// on the one connection: a frame that does not decode is skipped and never ends the socket.
    @Test(.timeLimit(.minutes(DeviceHubFuzzTests.timeLimitMinutes)))
    func theSocketSkipsBadFramesAndKeepsItsConnection() async throws {
        let run = try Self.run("DeviceHub.socket", seed: 0xDE71_0027_0005, iterations: 500)
        try await run.forEachAwaiting { rng in try await HubSocketCase(&rng).check() }
    }

    /// Session pushes for several sessions, with damaged frames naming them, read by a real
    /// ``DeviceHubSocket`` and handed to ``DeviceHub`` as the app hands them: the hub keeps each session's
    /// request and ticket as that session's own pushes say, so ending one session (or a frame that does
    /// not decode) leaves every other session as it was.
    @Test(.timeLimit(.minutes(DeviceHubFuzzTests.timeLimitMinutes)))
    func sessionPushesChangeOnlyTheirSession() async throws {
        let run = try Self.run("DeviceHub.sessions", seed: 0xDE71_0027_0006, iterations: 500)
        let stub = StubHub.routes([:])
        try await run.forEachAwaiting { rng in
            let script = try HubSessionsCase(&rng)
            try await script.play(on: stub)
            _ = stub.drainRequests()
        }
    }

    /// Any answer to any call (good, a protocol error, a bare status, garbage, a failed account
    /// exchange): the call returns or throws the ``DeviceHubError`` the contract names, never traps,
    /// and every request it made is signed by this device over the exact route it went to, with ids of
    /// any characters kept inside their own path segment.
    @Test(.timeLimit(.minutes(DeviceHubFuzzTests.timeLimitMinutes)))
    func signedCallsGiveAValueOrTheirTypedError() async throws {
        let run = try Self.run("DeviceHub.http", seed: 0xDE71_0027_0007, iterations: 300)
        let identity = DeviceIdentity.software()
        let stub = StubHub { _ in (500, "") }
        try await run.forEachAwaiting { rng in try await HubHTTPCase(&rng, identity: identity).check(on: stub) }
    }
}
