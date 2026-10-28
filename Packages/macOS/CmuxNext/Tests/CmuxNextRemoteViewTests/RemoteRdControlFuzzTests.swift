import CmuxFuzzSupport
import Foundation
import Testing
@testable import CmuxNextRemoteView

/// A remote host's control frames (JSON on the stream carrier's type-1 frames)
/// reach ``RemoteRdControl/parse(_:)``, then the setup reducer
/// (``RemoteRdHandshake``) and, for service bodies, the popup-stream changes
/// (``RemoteRdSurfaceStreamChange``). Seeded property tests on CmuxFuzzSupport
/// (p10-stability-024; long mode: CMUX_FUZZ_SECONDS):
///
/// - every control the viewer can meet parses back from its JSON as itself;
/// - mutated JSON parses or throws, never traps, and what parses encodes to JSON
///   that parses again, to a fixed point after one step (a body's integral double
///   becomes an integer once);
/// - a body nested deeper than ``RemoteRdJSON/maxDepth`` is refused, not recursed
///   into until a 512 KiB queue thread's stack runs out;
/// - the handshake never leaves an ended session, streams only after a welcome
///   for its service, and a refusal or an end is the end it names;
/// - a surface change never names stream 0, the page's stream.
@Suite nonisolated struct RemoteRdControlFuzzTests {
    static let alphabet: [Character] = ["a", "Z", "0", " ", "\"", "\\", "/", "\n", "\t", "\u{0}", "\u{1F}", "é", "\u{1F600}", "{", ":"]
    static let jsonTokens: [String] = [
        "{", "}", "[", "]", "\"", ":", ",", "null", "true", "false", "-0", "1e400", "1.5", "18446744073709551616",
        "\\u0000", "\\ud800", "\"t\":", "\"body\":", "\"service\"", "\"welcome\"", "\"started\"", "\"stream\":0",
    ]
    static let dictionary: [Data] = jsonTokens.map { Data($0.utf8) }
    static let kinds: [RemoteRdStreamKind] = [.video, .audio, .tiles, .popup, .upAudio, .upVideo, .unknown]

    /// One input of a property, its choices read from `data` (the libFuzzer entry, p10-stability-182).
    static func oneInput(_ data: Data) throws {
        var rng = FuzzRNG(replaying: data)
        switch rng.below(3) {
        case 0: try controlRoundTrip(&rng)
        case 1: try surfaceChange(&rng)
        default: try handshake(&rng)
        }
    }

    @Test func controlsRoundTripAndMutatedOnesParseOrThrow() throws {
        try FuzzRun("RemoteRdControl.parse", seed: 0x0C0A_7201_0000_0024, iterations: 10_000).forEach { rng in
            try Self.controlRoundTrip(&rng)
        }
    }

    @Test func surfaceChangesNeverNameThePageStream() throws {
        try FuzzRun("RemoteRdSurfaceStreamChange", seed: 0x0C0A_7201_0000_0025, iterations: 10_000).forEach { rng in
            try Self.surfaceChange(&rng)
        }
    }

    @Test func handshakeEndsOnceAndStaysEnded() throws {
        try FuzzRun("RemoteRdHandshake", seed: 0x0C0A_7201_0000_0026, iterations: 10_000).forEach { rng in
            try Self.handshake(&rng)
        }
    }

    @Test func oneInputTakesAnyBytes() throws {
        let run = try FuzzRun("RemoteRdControl.oneInput", seed: 0x0C0A, iterations: 512)
        // Choice tapes: the first byte picks the property (0 parse, 1 surface change, 2 handshake).
        let tapes: [[UInt8]] = [[0], [1], [2], [0, 8, 3], [2, 9, 1, 2, 3]]
        try run.forEachInput(run.corpus(seeds: tapes.map { Data($0) }), Self.oneInput)
    }

    @Test(arguments: [1, 64, RemoteRdJSON.maxDepth - 1, RemoteRdJSON.maxDepth, RemoteRdJSON.maxDepth + 1, 600, 10_000])
    func bodiesDeeperThanTheLimitAreRefused(depth: Int) {
        // `depth` arrays or objects, the innermost one empty: the deepest value sits at coding path depth `depth`.
        for (open, leaf, close) in [("[", "[]", "]"), ("{\"a\":", "{}", "}")] {
            let body = String(repeating: open, count: depth - 1) + leaf + String(repeating: close, count: depth - 1)
            let json = Data("{\"t\":\"service\",\"service\":\"desktop\",\"body\":\(body)}".utf8)
            let parsed = try? RemoteRdControl.parse(json)
            #expect((parsed != nil) == (depth <= RemoteRdJSON.maxDepth), "depth \(depth) of \(open)")
        }
    }

    // MARK: - Parse

    static func controlRoundTrip(_ rng: inout FuzzRNG) throws {
        let control = Self.control(&rng)
        let json = try control.json()
        let parsed = try RemoteRdControl.parse(json)
        try FuzzRun.check(parsed == control, "\(control) came back as \(parsed)")
        let mutator = FuzzMutator(dictionary: dictionary, maximumEdits: 4, maximumCount: 8_192)
        let mutated = mutator.mutate(json, using: &rng)
        guard let first = try? RemoteRdControl.parse(mutated), let again = try? first.json() else { return }
        let second: RemoteRdControl
        do {
            second = try RemoteRdControl.parse(again)
        } catch {
            try FuzzRun.check(false, "\(first) encoded to JSON that does not parse: \(error); from \(String(decoding: mutated, as: UTF8.self))")
            return
        }
        let third = try RemoteRdControl.parse(second.json())
        try FuzzRun.check(third == second, "no fixed point: \(second) then \(third)")
    }

    /// A control of every case, with values that survive JSON exactly (a body's doubles are not integral).
    static func control(_ rng: inout FuzzRNG) -> RemoteRdControl {
        switch rng.below(15) {
        case 0:
            return .hello(RemoteRdHello(
                user: text(&rng), install: text(&rng), principalClass: text(&rng), interactive: rng.bool(),
                udpPort: rng.bool() ? UInt16(rng.below(1 << 16)) : nil, maxDatagram: rng.int(in: -10...100_000),
                token: rng.bool() ? text(&rng) : nil, service: text(&rng), caps: (0..<rng.below(3)).map { _ in text(&rng) }
            ))
        case 1: return .start(key: text(&rng), mode: text(&rng))
        case 2: return .stop
        case 3:
            return .welcome(RemoteRdWelcome(
                encoder: text(&rng), width: UInt32(truncatingIfNeeded: rng.next()), height: UInt32(truncatingIfNeeded: rng.next()),
                maxDatagram: rng.int(in: 0...9_000), carrier: text(&rng), service: rng.bool() ? text(&rng) : nil,
                caps: rng.bool() ? (0..<rng.below(3)).map { _ in text(&rng) } : nil
            ))
        case 4: return .started(session: rng.next())
        case 5: return .refused(reason: text(&rng))
        case 6: return .ended(reason: text(&rng))
        case 7:
            return .stats(RemoteRdHostStats(
                kbps: UInt32(truncatingIfNeeded: rng.next()), frames: rng.next(), keyframes: rng.next(),
                cpuPercent: rng.double(in: 0...800), encodeMsP50: rng.double(in: 0...100), lossPercent: rng.double(in: 0...100)
            ))
        case 8: return .service(service: text(&rng), body: body(&rng, depth: 3))
        case 9: return .bulkCredit(transfer: rng.next(), offset: rng.next())
        case 10:
            return .streamOpen(RemoteRdStreamOpen(
                stream: UInt16(rng.below(1 << 16)), kind: kinds[rng.below(kinds.count)], codec: text(&rng),
                of: rng.bool() ? UInt16(rng.below(1 << 16)) : nil
            ))
        case 11: return .streamOpened(stream: UInt16(rng.below(1 << 16)))
        case 12: return .streamRefused(stream: UInt16(rng.below(1 << 16)), reason: text(&rng))
        case 13: return .streamClose(stream: UInt16(rng.below(1 << 16)))
        default: return .unknown("x-" + text(&rng))
        }
    }

    static func text(_ rng: inout FuzzRNG) -> String {
        rng.text(alphabet, 12)
    }

    /// A service body: any JSON value, nested up to `depth` arrays and objects.
    static func body(_ rng: inout FuzzRNG, depth: Int) -> RemoteRdJSON {
        switch rng.below(depth > 0 ? 7 : 5) {
        case 0: return .null
        case 1: return .bool(rng.bool())
        case 2: return .int(Int64(bitPattern: rng.next()))
        case 3: return .double(Double(rng.int(in: -1_000_000...1_000_000)) + 0.25)
        case 4: return .string(text(&rng))
        case 5: return .array((0..<rng.below(4)).map { _ in body(&rng, depth: depth - 1) })
        default:
            var object: [String: RemoteRdJSON] = [:]
            for _ in 0..<rng.below(4) {
                object[text(&rng)] = body(&rng, depth: depth - 1)
            }
            return .object(object)
        }
    }

    // MARK: - Surface streams

    /// `rb.surface.show` and `hide` bodies with fields of every JSON type and range, through JSON.
    static func surfaceChange(_ rng: inout FuzzRNG) throws {
        let numbers: [RemoteRdJSON] = [
            .int(0), .int(1), .int(-1), .int(65_535), .int(65_536), .int(Int64(UInt32.max)), .int(Int64(UInt32.max) + 1),
            .int(Int64(bitPattern: rng.next())), .double(2), .double(2.5), .double(-0.0), .string("3"), .null,
        ]
        var fields: [String: RemoteRdJSON] = [:]
        if !rng.oneIn(8) { fields["t"] = .string(["rb.surface.show", "rb.surface.hide", "rb.surface.other"][rng.below(3)]) }
        if !rng.oneIn(8) { fields["surface"] = numbers[rng.below(numbers.count)] }
        if !rng.oneIn(8) { fields["stream"] = numbers[rng.below(numbers.count)] }
        let usesFields = !rng.oneIn(16)
        let control = RemoteRdControl.service(service: "desktop", body: usesFields ? .object(fields) : body(&rng, depth: 2))
        guard case let .service(_, received) = try RemoteRdControl.parse(control.json()) else {
            try FuzzRun.check(false, "\(control) did not parse as a service message")
            return
        }
        let change = RemoteRdSurfaceStreamChange(received)
        if case let .show(_, stream) = change {
            try FuzzRun.check(stream != 0, "a surface shows on stream 0: \(received)")
        }
        let wellFormed: Bool = if case let .int(surface)? = fields["surface"], case let .int(stream)? = fields["stream"],
                                  case .string("rb.surface.show")? = fields["t"] {
            (0...Int64(UInt32.max)).contains(surface) && (1...65_535).contains(stream)
        } else {
            false
        }
        if wellFormed, usesFields {
            try FuzzRun.check(change != nil, "a well-formed show was refused: \(received)")
        }
    }

    // MARK: - Handshake

    /// A random order of host messages, viewer stops and carrier closes.
    static func handshake(_ rng: inout FuzzRNG) throws {
        let service = rng.bool() ? "desktop" : "browser"
        var handshake = RemoteRdHandshake(service: service)
        for _ in 0..<(1 + rng.below(12)) {
            let before = handshake
            switch rng.below(12) {
            case 0:
                handshake.viewerStopped()
                try FuzzRun.check(handshake.phase == before.phase && handshake.stopSent, "stop changed the phase")
                continue
            case 1:
                handshake.connectionClosed()
                let end: RemoteSessionEnd = before.stopSent ? .stoppedByViewer : .connectionLost
                try FuzzRun.check(before.isEnded ? handshake == before : handshake.phase == .ended(end), "close gave \(handshake.phase)")
                continue
            default:
                break
            }
            let control: RemoteRdControl = switch rng.below(6) {
            case 0: .welcome(RemoteRdWelcome(
                encoder: "vt", width: 1, height: 1, maxDatagram: 1152, carrier: "stream",
                service: [nil, service, "other"][rng.below(3)]
            ))
            case 1: .started(session: rng.next())
            case 2: .refused(reason: "no")
            case 3: .ended(reason: "bye")
            default: Self.control(&rng)
            }
            handshake.receive(control)
            if before.isEnded {
                try FuzzRun.check(handshake == before, "an ended session changed on \(control)")
                continue
            }
            switch control {
            case .refused: try FuzzRun.check(handshake.phase == .ended(.consentDenied), "refused gave \(handshake.phase)")
            case .ended:
                let end: RemoteSessionEnd = before.stopSent ? .stoppedByViewer : .hostStoppedSharing
                try FuzzRun.check(handshake.phase == .ended(end), "ended gave \(handshake.phase)")
            default: break
            }
            if case .streaming = handshake.phase {
                let routed = handshake.welcome?.service
                try FuzzRun.check(handshake.welcome != nil && (routed == nil || routed == service), "streaming without a welcome for \(service)")
            }
        }
    }
}
