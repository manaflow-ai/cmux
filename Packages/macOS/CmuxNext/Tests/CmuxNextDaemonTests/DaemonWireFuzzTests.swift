import CmuxFuzzSupport
import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextDaemon

/// Seeded fuzz of the app's side of the daemon wire (plans/cmux-next/chrome-parity/p10-stability.md, task 022):
/// the reader's line split (``LineSplitter``), the routing envelope of every line (``LineTransport/Envelope``),
/// event and reply decoding (``DaemonEvent/decode(name:line:)``, ``WireCoding/decodeResponse(_:from:decoder:)``),
/// the store's ``EventInbox`` under any order of appends, takes and holds, and a real ``LineTransport`` reading
/// a scripted peer. Chrome fuzzes the same layer: mojo/core/channel_fuzzer.cc feeds raw bytes to
/// `Channel::OnReadComplete`, and mojo/public/tools/fuzzers/mojolpm interleaves messages on live pipes.
///
/// The property everywhere: any input gives a value or a typed error, never a trap (a trap ends the run, so
/// a finished run is the proof). Each oracle is written from the contract in the doc comments of the code
/// under test: the transport's model routes each line by its fields, the inbox's model coalesces and
/// collapses by the rules in ``EventInbox``'s comment.
///
/// It runs only with `CMUX_DAEMON_FUZZ=1`; agents run it on the fleet, CI does not (Lawrence 2026-10-23):
///
/// ```
/// CMUX_DAEMON_FUZZ=1 swift test --filter DaemonWireFuzzTests
/// CMUX_DAEMON_FUZZ=1 CMUX_FUZZ_DEADLINE=$(( $(date +%s) + 300 )) swift test --filter DaemonWireFuzzTests
/// ```
///
/// The runs are CmuxFuzzSupport `FuzzRun`s (p10-stability-016): `CMUX_FUZZ_SEED` and `CMUX_FUZZ_ITERATIONS`
/// replay a failure, `CMUX_FUZZ_DEADLINE` gives the serialized suite one 5 minute long run, and with
/// `CMUX_FUZZ_ARTIFACTS` set a trap leaves the case it was in behind (`DaemonWire.<run>.inflight`).
@Suite(
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["CMUX_DAEMON_FUZZ"] == "1",
        "set CMUX_DAEMON_FUZZ=1; agents run it on the fleet (Lawrence 2026-10-23)"
    )
)
struct DaemonWireFuzzTests {
    /// Two minutes past a long run's budget, so the limit stops a hang and never a long run.
    static let timeLimitMinutes: Int = {
        let budget = (try? FuzzEnvironment.current())?.longModeBudget(from: Date()) ?? 0
        return 2 + Int((budget / 60).rounded(.up))
    }()

    /// One input of the in-process checks, its choices read from `data` (the libFuzzer entry,
    /// p10-stability-182). The transport run needs sockets and threads, so it is not part of it.
    static func oneInput(_ data: Data) throws {
        var rng = FuzzRNG(replaying: data)
        switch rng.below(6) {
        case 0:
            let stream = WireFuzzSplitterCase.stream(&rng)
            try WireFuzzSplitterCase.check(stream, &rng)
        case 1:
            let line = try WireFuzzLine.random(&rng, requests: 4)
            try WireFuzzEnvelopeCase.check(line, &rng)
        case 2:
            let sample = try WireFuzzEventCase.Sample.random(&rng)
            try WireFuzzEventCase.check(sample, &rng)
        case 3:
            try WireFuzzReplyCase.check(&rng)
        case 4:
            try WireFuzzInboxSequence(&rng).check()
        default:
            try WireFuzzRawLineCase.check(rng.bytes(512))
        }
    }

    @Test(.timeLimit(.minutes(DaemonWireFuzzTests.timeLimitMinutes)))
    func oneInputTakesAnyBytes() throws {
        let run = try FuzzRun("DaemonWire.oneInput", seed: 0x0DA3_0022_0001, iterations: 5_000)
        let seeds = [Data(), Data([0]), Data([1, 7, 0x0A]), Data([4, 3, 9, 200, 1]), Data(repeating: 0x5A, count: 64)]
        try run.forEachInput(try run.corpus(seeds: seeds)) { try Self.oneInput($0) }
    }

    /// Whole, chunked and byte-at-a-time reads cut the same lines, keep the same unfinished rest, and search
    /// each byte for a newline once (the linear bound of c997498fd634).
    @Test(.timeLimit(.minutes(DaemonWireFuzzTests.timeLimitMinutes)))
    func lineSplitterCutsEveryChunkingTheSame() throws {
        try FuzzRun("DaemonWire.lineSplitter", seed: 0x0DA3_0022_0002, iterations: 20_000).forEach { rng in
            let stream = WireFuzzSplitterCase.stream(&rng)
            try WireFuzzSplitterCase.check(stream, &rng)
        }
    }

    /// Every generated line routes by its fields; a mutated line decodes or is refused, never traps.
    @Test(.timeLimit(.minutes(DaemonWireFuzzTests.timeLimitMinutes)))
    func envelopesRouteEveryLineByItsFields() throws {
        try FuzzRun("DaemonWire.envelope", seed: 0x0DA3_0022_0003, iterations: 20_000).forEach { rng in
            let requests = 1 + rng.below(8)
            let line = try WireFuzzLine.random(&rng, requests: requests)
            try WireFuzzEnvelopeCase.check(line, &rng)
        }
    }

    /// A well-formed event decodes to its case, one with a field of the wrong type to `.unknown` with the
    /// line's payload; a mutated line under any name gives an event.
    @Test(.timeLimit(.minutes(DaemonWireFuzzTests.timeLimitMinutes)))
    func eventLinesDecodeToTheirCaseOrUnknown() throws {
        try FuzzRun("DaemonWire.event", seed: 0x0DA3_0022_0004, iterations: 20_000).forEach { rng in
            let sample = try WireFuzzEventCase.Sample.random(&rng)
            try WireFuzzEventCase.check(sample, &rng)
        }
    }

    /// A reply decodes to its value, and any damaged reply throws `DaemonError.malformedResponse`.
    @Test(.timeLimit(.minutes(DaemonWireFuzzTests.timeLimitMinutes)))
    func replyLinesDecodeOrThrowMalformedResponse() throws {
        try FuzzRun("DaemonWire.reply", seed: 0x0DA3_0022_0005, iterations: 10_000).forEach { rng in
            try WireFuzzReplyCase.check(&rng)
        }
    }

    /// Raw and mutated wire lines (JSON-token mutations of real lines) through every decoder the reader
    /// and the store run on a line.
    @Test(.timeLimit(.minutes(DaemonWireFuzzTests.timeLimitMinutes)))
    func rawLinesNeverTrapAnyDecoder() throws {
        let run = try FuzzRun("DaemonWire.rawLine", seed: 0x0DA3_0022_0006, iterations: 5_000)
        let corpus = try run.corpus(seeds: WireFuzzRawLineCase.seeds)
        let mutator = FuzzMutator(dictionary: WireFuzzJSON.tokens, maximumCount: 4096)
        try run.forEachInput(corpus, mutator: mutator) { line in
            try WireFuzzRawLineCase.check(line)
        }
    }

    /// Any sequence of appends, takes and holds: the frame flag, coalescing and the bounded collapse keep
    /// what ``EventInbox`` promises.
    @Test(.timeLimit(.minutes(DaemonWireFuzzTests.timeLimitMinutes)))
    func inboxInterleavingsKeepTheirGuarantees() throws {
        try FuzzRun("DaemonWire.inbox", seed: 0x0DA3_0022_0007, iterations: 10_000).forEach { rng in
            try WireFuzzInboxSequence(&rng).check()
        }
    }

    /// Threads that append and take at once: every event reaches exactly one batch, in its thread's order,
    /// and a frame is asked for at most once per take.
    @Test(.timeLimit(.minutes(DaemonWireFuzzTests.timeLimitMinutes)))
    func inboxConcurrentAppendsAndTakesDeliverEachEventOnce() throws {
        try FuzzRun("DaemonWire.inboxThreads", seed: 0x0DA3_0022_0008, iterations: 300).forEach { rng in
            try WireFuzzInboxThreads(&rng).check()
        }
    }

    /// A real transport reading a scripted peer: replies in any order (ids as numbers, decimal strings,
    /// unusable or missing), events, stream lines, garbage and empty lines, cut into any chunks. Each request
    /// gets the reply the routing contract names, events arrive in wire order with their indexes, and the
    /// close names a `daemon-shutdown` when one came.
    @Test(.timeLimit(.minutes(DaemonWireFuzzTests.timeLimitMinutes)))
    func transportRoutesInterleavedEventsAndReplies() async throws {
        let run = try FuzzRun("DaemonWire.transport", seed: 0x0DA3_0022_0009, iterations: 200)
        let peer = try WireFuzzPeer()
        defer { peer.stop() }
        // Each case waits on semaphores the reader thread signals: on a thread of its own, never on one of
        // the Swift concurrency pool.
        let cases = try await Self.onDedicatedThread("DaemonWireFuzz transport run") {
            try run.forEach { rng in try WireFuzzTransportCase(&rng).run(on: peer) }
        }
        #expect(cases >= run.iterations)
    }

    private static func onDedicatedThread(_ name: String, _ body: @escaping @Sendable () throws -> Int) async throws -> Int {
        let result: Result<Int, any Error> = await withCheckedContinuation { continuation in
            let thread = Thread {
                do {
                    continuation.resume(returning: .success(try body()))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
            thread.name = name
            thread.qualityOfService = .utility
            thread.start()
        }
        return try result.get()
    }
}

/// A value behind a lock, shared by the reader thread, producer threads and the checking thread.
final class WireFuzzLocked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) {
        mutex = Mutex(value)
    }

    func withLock<T: Sendable>(_ body: (inout Value) -> T) -> T {
        mutex.withLock { value in body(&value) }
    }
}

/// Small JSON values and lines for the generators, and the tokens the byte mutator splices in.
enum WireFuzzJSON {
    static let text: [Character] = ["a", "z", "7", "-", "_", " ", "é", "✓", "\"", "\\", "/", "\t", "\u{0}", "\u{1F600}", "{", "}"]
    static let keys: [Character] = ["a", "b", "k", "_", "1"]

    static let tokens: [Data] = [
        "{", "}", "[", "]", "\"", ":", ",", "null", "true", "false", "-0", "1e400", "18446744073709551616",
        "\"event\"", "\"id\"", "\"ok\"", "\"error\"", "\"data\"", "\"type\"", "\"stream_item\"", "\"surface\"",
        "\\u0000", "\\ud800", "\n", "\u{FEFF}",
    ].map { Data($0.utf8) }

    /// One line of JSON (no newline) for `object`: a dictionary, an array or a fragment. An object
    /// JSONSerialization cannot write is a failed property, not an Objective-C exception.
    static func bytes(_ object: Any) throws -> [UInt8] {
        try FuzzRun.check(JSONSerialization.isValidJSONObject([object]), "the generator built an object JSON cannot hold")
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
        let bytes = [UInt8](data)
        try FuzzRun.check(!bytes.contains(0x0A), "a serialized line holds a newline")
        return bytes
    }

    /// A small random JSON value, never null at the top (a null `data` is not an object to decode).
    static func value(_ rng: inout FuzzRNG, depth: Int = 0) -> Any {
        switch rng.below(depth >= 2 ? 4 : 6) {
        case 0: return rng.int(in: -1000...1_000_000)
        case 1: return rng.text(text, 12)
        case 2: return rng.bool()
        case 3: return depth == 0 ? "null" : NSNull()
        case 4: return (0..<rng.below(4)).map { _ in value(&rng, depth: depth + 1) }
        default: return object(&rng, depth: depth + 1)
        }
    }

    /// An object whose keys all start with `x`, so it never sets a field the code under test reads.
    static func object(_ rng: inout FuzzRNG, depth: Int = 0) -> [String: Any] {
        var object: [String: Any] = [:]
        for _ in 0..<rng.below(4) {
            object["x" + rng.text(keys, 6)] = value(&rng, depth: depth + 1)
        }
        return object
    }

    /// `value`, or a failed property that says what was missing.
    static func required<T>(_ value: T?, _ message: @autoclosure () -> String) throws -> T {
        guard let value else { throw FuzzError.property(message(), location: "DaemonWireFuzzTests") }
        return value
    }
}
