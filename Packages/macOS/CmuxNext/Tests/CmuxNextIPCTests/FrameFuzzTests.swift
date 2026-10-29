import CmuxFuzzSupport
import CmuxNextIPC
import Foundation
import Testing

/// Seeded fuzz of the app's ``FrameReader`` (plans/cmux-next/chrome-parity/p05-ipc.md, task 057). It runs
/// only with `CMUX_IPC_FUZZ=1`; agents run it on the fleet, CI does not (Lawrence 2026-10-23):
///
/// ```
/// CMUX_IPC_FUZZ=1 swift test --filter FrameFuzzTests
/// ```
///
/// Each case is random bytes, a valid stream of JSON lines and frames, a golden vector from
/// cmux-tui/spec/fixtures/ipc-frames, or one of those mutated the way Mojo's fuzzers mutate messages
/// (chromium mojo/core/channel_fuzzer.cc feeds raw bytes to `Channel::OnReadComplete`). The oracle is
/// ``WireModel``, a byte-level copy of the check order and reason strings of the Rust reader
/// (cmux-tui/crates/cmux-ipc/src/reader.rs and frame.rs, task 050), which the task 054 paragraph of
/// p05-ipc.md makes the Swift reader's contract, so the reader is never its own judge:
///
/// - the reader never traps (a trap ends the run: 0 crashes means the run finishes);
/// - its messages are the model's messages, byte for byte (a frame is its header's 16 wire bytes and
///   its payload, a line its text without `\n`), and it ends where the model ends, cleanly or with the
///   same `bad_message` reason, which stays the answer on every later call;
/// - one push, random chunks and one byte at a time cut the same messages;
/// - a payload held until the end of the case still has its bytes after later reads reuse the pooled
///   read buffers (the no-copy slices of OUTPUT, SNAPSHOT and REPLAY at or above 4 KiB).
///
/// The run is a CmuxFuzzSupport `FuzzRun`: `CMUX_FUZZ_SEED` and
/// `CMUX_FUZZ_ITERATIONS` change it, `CMUX_FUZZ_SECONDS` or `CMUX_FUZZ_DEADLINE` make it a long run,
/// a failed case prints the variables that replay it, and with `CMUX_FUZZ_ARTIFACTS` set a trap
/// leaves the case it was in behind (`FrameFuzz.reader.inflight`).
@Suite(
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["CMUX_IPC_FUZZ"] == "1",
        "set CMUX_IPC_FUZZ=1; agents run it on the fleet (Lawrence 2026-10-23)"
    )
)
struct FrameFuzzTests {
    private static let defaultCases = 100_000
    /// The default run; `CMUX_FUZZ_SEED` picks another.
    private static let defaultSeed: UInt64 = 0x0C3A_0053_F022_5EED
    /// The default run's budget; a long run goes on for its own budget instead.
    private static let timeBudget: Duration = .seconds(60)
    /// Two minutes past a long run's budget, so the limit stops a hang and never a long run.
    static let timeLimitMinutes: Int = {
        let budget = (try? FuzzEnvironment.current())?.longModeBudget(from: Date()) ?? 0
        return 2 + Int((budget / 60).rounded(.up))
    }()

    /// Close reasons the reader itself can return; `bad_magic` and `aux_mismatch` come only from
    /// building a header by hand.
    private static let readerReasons = [
        "unknown_kind", "oversize", "data_on_control_stream", "unknown_priority", "unknown_flags",
        "frames_not_negotiated", "line_too_long", "invalid_utf8", "truncated",
    ]

    @Test(.timeLimit(.minutes(FrameFuzzTests.timeLimitMinutes)))
    func seededInputsMatchTheWireModel() throws {
        let run = try FuzzRun("FrameFuzz.reader", seed: Self.defaultSeed, iterations: Self.defaultCases)
        let seeds = try Self.fixtureSeeds()
        let clock = ContinuousClock()
        let started = clock.now
        var ends: [String: Int] = [:]
        let cases = try run.forEach { rng in
            let fuzzCase = FuzzCase(rng: &rng, seeds: seeds)
            let feed = Feed(rng: &rng, inputCount: fuzzCase.input.count)
            do throws(Mismatch) {
                let end = try fuzzCase.check(feed: feed, rng: &rng)
                ends[end, default: 0] += 1
            } catch {
                throw Mismatch(message: "frame_fuzz: \(error.message); \(fuzzCase.describe(feed: feed))")
            }
        }
        let elapsed = clock.now - started
        let summary = ends.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
        Self.log("frame_fuzz: \(cases) cases, seed \(run.seed), \(seeds.count) fixture seeds, \(elapsed); ends: \(summary)")
        if !run.environment.isLongMode {
            #expect(elapsed < Self.timeBudget, "frame_fuzz took \(elapsed), budget \(Self.timeBudget)")
        }
        if cases >= 10_000 {
            let missing = Self.readerReasons.filter { ends[$0] == nil }
            #expect(missing.isEmpty, "no case ended in \(missing); the generator lost coverage")
            #expect(ends["clean"] != nil, "no case ended cleanly")
        }
    }

    /// Every `.bin` golden vector of p05-ipc-050, shared with the Rust reader's tests.
    private static func fixtureSeeds() throws -> [[UInt8]] {
        var root = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("cmux-tui/spec").path) {
            let parent = root.deletingLastPathComponent()
            guard parent.path != root.path else { throw FuzzSetupError.noSpecDirectory(start: #filePath) }
            root = parent
        }
        let directory = root.appendingPathComponent("cmux-tui/spec/fixtures/ipc-frames")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".bin") }
            .sorted()
        return try names.map { [UInt8](try Data(contentsOf: directory.appendingPathComponent($0))) }
    }

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

private enum FuzzSetupError: Error, CustomStringConvertible {
    case noSpecDirectory(start: String)

    var description: String {
        switch self {
        case let .noSpecDirectory(start): "no cmux-tui/spec above \(start)"
        }
    }
}

/// Why a case failed, with what the reader and the model said.
private struct Mismatch: Error, CustomStringConvertible {
    let message: String

    var description: String { message }
}

// MARK: - The reader under test

/// The fuzzer's only contact with ``FrameReader``: bytes in, owned bytes and close reasons out. Every call
/// here is the interface in the task 054 paragraph of p05-ipc.md; change both together.
private struct Subject {
    enum Step {
        case pending
        case message(Received)
        case bad(String)
    }

    /// A message as the reader returned it, and the same message read again at the end of the case.
    struct Received {
        let bytes: [UInt8]
        let reread: () -> [UInt8]
    }

    private var reader: FrameReader

    init(_ model: WireModel) {
        reader = FrameReader(limits: FrameReader.Limits(maxLine: model.maxLine, maxFramePayload: model.maxFramePayload))
        if model.negotiated { reader.negotiateFrames() }
    }

    mutating func push(_ bytes: ArraySlice<UInt8>) {
        bytes.withUnsafeBytes { reader.push($0) }
    }

    mutating func markEndOfStream() {
        reader.markEndOfStream()
    }

    mutating func next() -> Step {
        do {
            guard let message = try reader.next() else { return .pending }
            switch message {
            case let .json(line):
                return .message(Received(bytes: Array(line), reread: { Array(line) }))
            case let .frame(frame):
                return .message(Received(bytes: Self.wireBytes(frame), reread: { Self.wireBytes(frame) }))
            }
        } catch {
            return .bad(Self.reason(error))
        }
    }

    private static func wireBytes(_ frame: Frame) -> [UInt8] {
        Array(frame.header.encode()) + Array(frame.payload)
    }

    private static func reason(_ error: any Error) -> String {
        guard let bad = error as? BadMessage else { return "untyped error \(error)" }
        return bad.reason
    }
}

// MARK: - The oracle

/// A byte-level copy of the Rust reader (cmux-ipc/src/reader.rs, frame.rs): its order of checks and its
/// reason strings, which the task 054 paragraph of p05-ipc.md requires of the Swift reader. The header
/// layout, kinds and 32 MiB cap are section 3.2; the line rules (`line_too_long` against `maxLine`, strict
/// UTF-8 as `invalid_utf8`, an unterminated trailing line at the end is a message) and the frame rules
/// (`frames_not_negotiated` on any 0xFF before negotiation, `truncated` at the end) come from reader.rs. A
/// message boundary starting with 0xFF is a frame, anything else a JSON line up to `\n`; a header is refused
/// before any payload byte counts.
private struct WireModel {
    static let magic: UInt8 = 0xFF
    static let headerLength = 16
    /// 32 MiB, the largest payload any header may declare.
    static let maxFramePayloadCap: UInt32 = 32 * 1024 * 1024
    /// 16 MiB, the daemon's Unix ingress line limit.
    static let maxJSONLineDefault = 16 * 1024 * 1024
    /// OUTPUT .. RING_ACK (1-11), then the call kinds REQUEST .. CANCEL (16-20).
    static let kinds: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 16, 17, 18, 19, 20]
    /// OUTPUT, SNAPSHOT and REPLAY: the kinds whose large payloads are no-copy slices.
    static let sliceKinds: [UInt8] = [1, 4, 6]
    static let sharedBufferKind: UInt8 = 10
    static let knownFlags: UInt8 = 0b1_1111
    static let priorityCount: UInt8 = 4

    let negotiated: Bool
    let maxLine: Int
    let maxFramePayload: UInt32

    static func isCall(_ kind: UInt8) -> Bool { kind >= 16 }

    /// Stream data needs a client-minted stream; stream 0 is the control sequence.
    static func needsDataStream(_ kind: UInt8) -> Bool { !isCall(kind) && kind != sharedBufferKind }

    struct Outcome: Equatable {
        var messages: [[UInt8]] = []
        var end = "clean"
    }

    func outcome(of input: [UInt8]) -> Outcome {
        var outcome = Outcome()
        var at = 0
        while at < input.count {
            if input[at] == Self.magic {
                guard negotiated else { return ended(outcome, "frames_not_negotiated") }
                guard input.count - at >= Self.headerLength else { return ended(outcome, "truncated") }
                if let refusal = headerRefusal(input, at: at) { return ended(outcome, refusal) }
                let frameLength = Self.headerLength + Int(Self.littleEndian32(input, at: at + 4))
                guard input.count - at >= frameLength else { return ended(outcome, "truncated") }
                outcome.messages.append(Array(input[at..<(at + frameLength)]))
                at += frameLength
            } else {
                let end = input[at...].firstIndex(of: UInt8(ascii: "\n")) ?? input.count
                guard end - at <= maxLine else { return ended(outcome, "line_too_long") }
                let line = input[at..<end]
                guard Self.isUTF8(line) else { return ended(outcome, "invalid_utf8") }
                outcome.messages.append(Array(line))
                at = min(end + 1, input.count)
            }
        }
        return outcome
    }

    private func ended(_ outcome: Outcome, _ reason: String) -> Outcome {
        var outcome = outcome
        outcome.end = reason
        return outcome
    }

    /// The reason a 16-byte header at `at` is refused, or nil.
    private func headerRefusal(_ input: [UInt8], at: Int) -> String? {
        let kind = input[at + 1]
        guard Self.kinds.contains(kind) else { return "unknown_kind" }
        guard Self.littleEndian32(input, at: at + 4) <= min(maxFramePayload, Self.maxFramePayloadCap) else {
            return "oversize"
        }
        if Self.isCall(kind) {
            guard input[at + 14] < Self.priorityCount else { return "unknown_priority" }
            guard input[at + 15] & ~Self.knownFlags == 0 else { return "unknown_flags" }
            return nil
        }
        let stream = UInt16(input[at + 2]) | UInt16(input[at + 3]) << 8
        return stream == 0 && Self.needsDataStream(kind) ? "data_on_control_stream" : nil
    }

    static func littleEndian32(_ bytes: [UInt8], at: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[at + $1]) << (8 * $1) }
    }

    /// Strict UTF-8: repaired decoding changes the bytes exactly when they are not valid.
    static func isUTF8(_ bytes: ArraySlice<UInt8>) -> Bool {
        String(decoding: bytes, as: UTF8.self).utf8.elementsEqual(bytes)
    }
}

// MARK: - Cases

private enum Feed: CustomStringConvertible {
    /// One push of the whole input.
    case whole
    /// Pushes of random chunks, draining after each.
    case chunks
    /// One byte per push: every split point at once.
    case bytes

    init(rng: inout FuzzRNG, inputCount: Int) {
        switch rng.below(8) {
        case 0: self = inputCount <= 256 ? .bytes : .chunks
        case 1...4: self = .chunks
        default: self = .whole
        }
    }

    var description: String {
        switch self {
        case .whole: "whole"
        case .chunks: "chunks"
        case .bytes: "bytes"
        }
    }
}

private struct FuzzCase {
    let input: [UInt8]
    let model: WireModel

    init(rng: inout FuzzRNG, seeds: [[UInt8]]) {
        switch rng.below(10) {
        case 0:
            input = rng.bytes(count: rng.below(512))
        case 1:
            input = [WireModel.magic] + rng.bytes(count: 1 + rng.below(80))
        case 2:
            input = Generator.validStream(&rng)
        case 3 where !seeds.isEmpty:
            input = seeds[rng.below(seeds.count)]
        default:
            var base = !seeds.isEmpty && rng.oneIn(3) ? seeds[rng.below(seeds.count)] : Generator.validStream(&rng)
            for _ in 0...rng.below(4) {
                Generator.mutate(&base, &rng)
            }
            input = base
        }
        let small = rng.oneIn(4)
        let maxLine = small ? rng.below(64) : WireModel.maxJSONLineDefault
        let maxFramePayload = small ? UInt32(rng.below(256)) : WireModel.maxFramePayloadCap
        model = WireModel(negotiated: !rng.oneIn(8), maxLine: maxLine, maxFramePayload: maxFramePayload)
    }

    /// Runs one push and `feed` against the model; returns how the case ended.
    func check(feed: Feed, rng: inout FuzzRNG) throws(Mismatch) -> String {
        let expected = model.outcome(of: input)
        try run(.whole, rng: &rng, expected: expected)
        if case .whole = feed {} else {
            try run(feed, rng: &rng, expected: expected)
        }
        return expected.end
    }

    private func run(_ feed: Feed, rng: inout FuzzRNG, expected: WireModel.Outcome) throws(Mismatch) {
        var subject = Subject(model)
        var received: [Subject.Received] = []
        // Every message consumes at least one byte.
        var budget = input.count
        var end: String?
        switch feed {
        case .whole:
            subject.push(input[...])
            subject.markEndOfStream()
            end = try drain(&subject, into: &received, budget: &budget)
        case .chunks, .bytes:
            var at = 0
            while at < input.count, end == nil {
                let count = if case .bytes = feed { 1 } else { 1 + rng.below(input.count - at) }
                subject.push(input[at..<(at + count)])
                at += count
                end = try drain(&subject, into: &received, budget: &budget)
            }
            if end == nil {
                subject.markEndOfStream()
                end = try drain(&subject, into: &received, budget: &budget)
            }
        }
        let got = WireModel.Outcome(messages: received.map(\.bytes), end: end ?? "clean")
        guard got == expected else {
            throw Mismatch(message: "\(feed): reader \(Self.summary(got)) but the model \(Self.summary(expected))")
        }
        if let reason = end {
            guard case .bad(reason) = subject.next() else {
                throw Mismatch(message: "\(feed): \(reason) was not the answer of the next call")
            }
            subject.push(Array("{\"cmd\":\"after\"}\n".utf8)[...])
            guard case .bad(reason) = subject.next() else {
                throw Mismatch(message: "\(feed): bytes after \(reason) were read; a bad message must stay the answer")
            }
        } else {
            guard case .pending = subject.next() else {
                throw Mismatch(message: "\(feed): the call after a clean end returned more than nothing")
            }
        }
        for (index, message) in received.enumerated() where message.reread() != message.bytes {
            throw Mismatch(message: "\(feed): message \(index) changed after later reads; a pooled buffer was reused under a held payload")
        }
    }

    /// Takes messages until the reader needs bytes (nil) or refuses them (the reason).
    private func drain(_ subject: inout Subject, into received: inout [Subject.Received], budget: inout Int) throws(Mismatch) -> String? {
        while true {
            switch subject.next() {
            case .pending:
                return nil
            case let .bad(reason):
                return reason
            case let .message(message):
                budget -= 1
                guard budget >= 0 else { throw Mismatch(message: "more messages than input bytes: no progress") }
                received.append(message)
            }
        }
    }

    private static func summary(_ outcome: WireModel.Outcome) -> String {
        let sizes = outcome.messages.map { "\($0.first == WireModel.magic ? "frame" : "line"):\($0.count)" }
        return "cut [\(sizes.joined(separator: ", "))] and ended \(outcome.end)"
    }

    func describe(feed: Feed) -> String {
        let shown = input.prefix(512).map { String(format: "%02x", $0) }.joined()
        return "feed \(feed), negotiated \(model.negotiated), max line \(model.maxLine), max payload \(model.maxFramePayload), "
            + "\(input.count) input bytes: \(shown)\(input.count > 512 ? "..." : "")"
    }
}

// MARK: - Generation

/// Choices the generator below makes, drawn from the shared seeded generator.
private extension FuzzRNG {
    mutating func pick<T>(_ items: [T]) -> T {
        items[below(items.count)]
    }

    /// One of `items` or, as often as each of them, a random byte.
    mutating func pickOrByte(_ items: [UInt8]) -> UInt8 {
        let random = byte()
        let index = below(items.count + 1)
        return index < items.count ? items[index] : random
    }
}

private struct Generator {
    static let lines = [
        "{\"cmd\":\"identify\",\"id\":1}",
        "",
        "{\"event\":\"ünïcødé ✓\"}",
        "{\"id\":7,\"result\":{\"ok\":true}}\r",
        "   ",
        "{\"cmd\":\"send-input\",\"text\":\"\\u001b[A\"}",
    ]
    static let lineCharacters: [Character] = ["{", "}", "\"", ":", "a", "7", " ", "\r", "é", "\u{1F600}"]

    /// One to eight JSON lines and frames of random kinds, as one byte stream.
    static func validStream(_ rng: inout FuzzRNG) -> [UInt8] {
        var out: [UInt8] = []
        for _ in 0...rng.below(8) {
            if rng.oneIn(3) {
                let line = rng.oneIn(2)
                    ? rng.pick(lines)
                    : String((0..<rng.below(48)).map { _ in rng.pick(lineCharacters) })
                out.append(contentsOf: line.utf8)
                out.append(UInt8(ascii: "\n"))
            } else {
                out.append(contentsOf: frame(&rng))
            }
        }
        return out
    }

    /// One valid frame's wire bytes. Payloads hold newlines and 0xFF, which must not cut a frame, and
    /// now and then OUTPUT, SNAPSHOT or REPLAY bytes above the 4 KiB no-copy threshold.
    static func frame(_ rng: inout FuzzRNG) -> [UInt8] {
        let kind = rng.pick(WireModel.kinds)
        let stream: UInt16 = if WireModel.needsDataStream(kind) {
            UInt16(1 + rng.below(Int(UInt16.max)))
        } else if rng.oneIn(2) {
            0
        } else {
            UInt16(truncatingIfNeeded: rng.next())
        }
        var aux: [UInt8] = withUnsafeBytes(of: rng.next().littleEndian) { Array($0) }
        if WireModel.isCall(kind) {
            aux[6] = UInt8(rng.below(Int(WireModel.priorityCount)))
            aux[7] = rng.byte() & WireModel.knownFlags
        }
        let length: Int = if WireModel.sliceKinds.contains(kind), rng.oneIn(24) {
            4096 + rng.below(12_288)
        } else if rng.oneIn(16) {
            0
        } else {
            rng.below(300)
        }
        var payload = rng.bytes(count: length)
        for index in payload.indices where payload[index] & 0b111 == 0 {
            payload[index] = payload[index] & 0b1000 == 0 ? UInt8(ascii: "\n") : WireModel.magic
        }
        return header(kind: kind, stream: stream, length: UInt32(length), aux: aux) + payload
    }

    static func header(kind: UInt8, stream: UInt16, length: UInt32, aux: [UInt8]) -> [UInt8] {
        var header: [UInt8] = [WireModel.magic, kind]
        withUnsafeBytes(of: stream.littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: length.littleEndian) { header.append(contentsOf: $0) }
        header.append(contentsOf: aux)
        return header
    }

    /// Payload lengths at and around every limit.
    static func interestingLength(_ rng: inout FuzzRNG) -> UInt32 {
        let random = UInt32(truncatingIfNeeded: rng.next())
        let small = UInt32(rng.below(64))
        let cap = WireModel.maxFramePayloadCap
        let choices: [UInt32] = [0, 1, UInt32(WireModel.headerLength), 255, 256, cap - 1, cap, cap + 1, UInt32.max, random, small]
        return rng.pick(choices)
    }

    /// One structural or byte-level mutation.
    static func mutate(_ bytes: inout [UInt8], _ rng: inout FuzzRNG) {
        let count = bytes.count
        switch rng.below(10) {
        case 0 where count > 0:
            bytes[rng.below(count)] ^= 1 << rng.below(8)
        case 1 where count > 0:
            bytes[rng.below(count)] = rng.pickOrByte([0x00, WireModel.magic, UInt8(ascii: "\n"), 0x7F, 0x80, 0xC3])
        case 2:
            let at = rng.below(count + 1)
            bytes.insert(contentsOf: rng.bytes(count: 1 + rng.below(16)), at: at)
        case 3 where count > 0:
            let start = rng.below(count)
            bytes.removeSubrange(start..<(start + 1 + rng.below(count - start)))
        case 4:
            bytes.removeLast(count - rng.below(count + 1))
        case 5 where count > 0:
            let start = rng.below(count)
            let copy = Array(bytes[start..<(start + 1 + rng.below(min(count - start, 64)))])
            bytes.insert(contentsOf: copy, at: rng.below(count + 1))
        case 6:
            bytes.insert(WireModel.magic, at: rng.below(count + 1))
        case 7:
            let more = validStream(&rng)
            bytes += more.prefix(rng.below(more.count + 1))
        default:
            mutateHeader(&bytes, &rng)
        }
    }

    /// Rewrites one field of a header that starts at a 0xFF byte.
    static func mutateHeader(_ bytes: inout [UInt8], _ rng: inout FuzzRNG) {
        let starts = bytes.indices.filter { bytes[$0] == WireModel.magic && $0 + WireModel.headerLength <= bytes.count }
        guard !starts.isEmpty else { return }
        let at = rng.pick(starts)
        switch rng.below(6) {
        case 0:
            bytes[at + 1] = rng.pickOrByte([0, 12, 15, 21, 0xFE])
        case 1:
            let length: [UInt8] = withUnsafeBytes(of: interestingLength(&rng).littleEndian) { Array($0) }
            bytes.replaceSubrange((at + 4)..<(at + 8), with: length)
        case 2:
            bytes[at + 2] = 0
            bytes[at + 3] = 0
        case 3:
            bytes[at + 14] = rng.pickOrByte([4, 0xFF])
        case 4:
            bytes[at + 15] = rng.pickOrByte([1 << 5, 0x80])
        default:
            let aux: [UInt8] = withUnsafeBytes(of: rng.next().littleEndian) { Array($0) }
            bytes.replaceSubrange((at + 8)..<(at + 16), with: aux)
        }
    }
}
