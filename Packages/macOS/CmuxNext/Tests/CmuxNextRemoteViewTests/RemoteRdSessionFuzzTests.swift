import CmuxFuzzSupport
import Foundation
import Testing
@testable import CmuxNextRemoteView

/// The stream carrier's bytes as ``RemoteRdStreamTransport`` handles them: cut
/// by ``RemoteRdStreamSplitter``, pushed into the shared Rust core
/// (``RemoteRdSession``, cmux-rd-ffi), then access units, messages, control JSON
/// and feedback taken out through the Swift side of the C ABI. Seeded property
/// tests on CmuxFuzzSupport (long mode: CMUX_FUZZ_SECONDS):
///
/// - a host's valid stream (video frames in one or more shards, `cmux.rd/1`
///   layout from cmux-rd-proto datagram.rs and frame.rs, control frames and
///   cursor datagrams between them) comes out whole for any chunking: every frame
///   in order with its number, flags, capture time and access unit, every control
///   as sent, every datagram byte for byte;
/// - the same stream mutated never traps the wrapper, and what comes out is
///   bounded by what went in: no access unit or message larger than the bytes
///   pushed, no more of them than stream frames pushed.
@Suite nonisolated struct RemoteRdSessionFuzzTests {
    /// One input, its choices read from `data` (the libFuzzer entry).
    static func oneInput(_ data: Data) throws {
        var rng = FuzzRNG(replaying: data)
        try SessionCase(&rng).check(&rng)
    }

    @Test func aSessionGivesBackWhatTheHostSentAndBoundsTheRest() throws {
        try FuzzRun("RemoteRdSession.stream", seed: 0x0D5E_5510_0000_0024, iterations: 2_000).forEach { rng in
            try SessionCase(&rng).check(&rng)
        }
    }

    @Test func oneInputTakesAnyBytes() throws {
        let run = try FuzzRun("RemoteRdSession.oneInput", seed: 0x0D5E, iterations: 256)
        // Choice tapes: the first byte picks valid (0) or mutated, the next ones the stream's shape.
        let tapes: [[UInt8]] = [[0], [1], [0, 2, 3, 0, 5], [1, 1, 1, 1]]
        try run.forEachInput(run.corpus(seeds: tapes.map { Data($0) }), Self.oneInput)
    }
}

extension RemoteRdSessionFuzzTests {
    /// A frame as the host sent it and as ``RemoteRdSession`` must release it.
    nonisolated struct SentFrame: Equatable {
        var frame: UInt32
        var flags: UInt8
        var tCaptureMicros: UInt64
        var accessUnit: [UInt8]
    }

    nonisolated struct SessionCase {
        static let referenceNone = UInt32.max
        static let videoKind: UInt8 = 1
        static let cursorKind: UInt8 = 6
        static let keyframeFlag: UInt8 = 0b0001
        static let now: UInt64 = 1_000_000

        let bytes: [UInt8]
        let mutated: Bool
        let frames: [SentFrame]
        let controls: [RemoteRdControl]
        let datagrams: [[UInt8]]
        /// Stream frames in `bytes` before any mutation (each one at least 5 bytes).
        let streamFrames: Int

        init(_ rng: inout FuzzRNG) throws {
            mutated = !rng.oneIn(3)
            let shardLength = [48, 300, 1_136][rng.below(3)]
            var out: [UInt8] = []
            var frames: [SentFrame] = []
            var controls: [RemoteRdControl] = []
            var datagrams: [[UInt8]] = []
            var count = 0
            var sequence: UInt16 = 0
            for number in 1...UInt32(1 + rng.below(6)) {
                if rng.oneIn(3) {
                    let control = RemoteRdControlFuzzTests.control(&rng)
                    controls.append(control)
                    out += try Self.streamFrame(control.json(), control: true)
                    count += 1
                }
                if rng.oneIn(4) {
                    sequence &+= 1
                    let datagram = Self.header(flags: 0, kind: Self.cursorKind, frame: 0, index: 0, count: 0, sequence: sequence)
                        + rng.bytes(count: rng.below(24))
                    datagrams.append(datagram)
                    out += try Self.streamFrame(Data(datagram), control: false)
                    count += 1
                }
                let key = number == 1 || rng.oneIn(5)
                let frame = SentFrame(
                    frame: number, flags: key ? Self.keyframeFlag : 0, tCaptureMicros: UInt64(rng.below(1 << 30)),
                    accessUnit: RemoteAnnexBFuzzTests.validAccessUnit(codec: .h264, &rng)
                )
                frames.append(frame)
                for shard in Self.shards(of: frame, reference: key ? Self.referenceNone : number - 1, length: shardLength, sequence: &sequence) {
                    out += try Self.streamFrame(Data(shard), control: false)
                    count += 1
                }
            }
            if mutated {
                let mutator = FuzzMutator(dictionary: RemoteAnnexBFuzzTests.dictionary, maximumEdits: 6, maximumCount: 1 << 16)
                bytes = [UInt8](mutator.mutate(Data(out), using: &rng))
            } else {
                bytes = out
            }
            self.frames = frames
            self.controls = controls
            self.datagrams = datagrams
            streamFrames = count
        }

        /// Feeds `bytes` in random chunks the way the transport does, then checks what came out.
        func check(_ rng: inout FuzzRNG) throws {
            guard let session = RemoteRdSession(carrier: .stream) else {
                try FuzzRun.check(false, "the core could not allocate a session")
                return
            }
            var splitter = RemoteRdStreamSplitter()
            var output = Output()
            var pushed = 0
            var failed = false
            var at = 0
            feed: while at < bytes.count {
                let count = rng.oneIn(3) ? bytes.count - at : 1 + rng.below(min(bytes.count - at, 700))
                for segment in splitter.split(Data(bytes[at..<(at + count)])) {
                    do {
                        try session.push(streamBytes: segment.bytes, nowMicros: Self.now)
                    } catch {
                        // The transport ends the session here.
                        failed = true
                        break feed
                    }
                    pushed += segment.bytes.count
                    if segment.endsControlFrame { try output.takeMessages(session, pushed: pushed) }
                }
                at += count
                try output.take(session, pushed: pushed)
            }
            let bound = mutated ? pushed / 5 + 1 : streamFrames
            try FuzzRun.check(output.units.count + output.messages.count <= bound, "\(output.units.count) units and \(output.messages.count) messages from \(pushed) bytes")
            guard !mutated else { return }
            try FuzzRun.check(!failed, "a valid stream failed the session")
            let released = output.units.map {
                SentFrame(frame: $0.frame, flags: $0.flags.rawValue, tCaptureMicros: $0.tCaptureMicros, accessUnit: [UInt8]($0.data))
            }
            try FuzzRun.check(released == frames, "released frames \(released.map(\.frame)) but the host sent \(frames.map(\.frame))")
            let parsed = output.messages.compactMap { message -> RemoteRdControl? in
                guard case let .control(json) = message else { return nil }
                return try? RemoteRdControl.parse(json)
            }
            try FuzzRun.check(parsed == controls, "controls \(parsed) but the host sent \(controls)")
            let received = output.messages.compactMap { message -> [UInt8]? in
                guard case let .datagram(datagram) = message else { return nil }
                return [UInt8](datagram)
            }
            try FuzzRun.check(received == datagrams, "\(received.count) datagrams but the host sent \(datagrams.count)")
        }

        /// What came out of the session, checked against the bytes pushed so far as it is taken.
        nonisolated struct Output {
            var units: [RemoteAccessUnit] = []
            var messages: [RemoteRdMessage] = []

            mutating func take(_ session: RemoteRdSession, pushed: Int) throws {
                _ = try? session.tick(nowMicros: SessionCase.now)
                while let popped = try? session.popAccessUnit(codec: .h264) {
                    try FuzzRun.check(popped.stream == 0, "a unit of stream \(popped.stream), which was never opened")
                    try FuzzRun.check(popped.unit.data.count <= pushed, "a \(popped.unit.data.count)-byte unit from \(pushed) bytes")
                    try FuzzRun.check(units.count <= pushed, "more units than bytes pushed")
                    // What the decoder does first with a unit.
                    _ = RemoteAnnexB().parse(popped.unit.data, codec: popped.unit.codec)
                    units.append(popped.unit)
                }
                try takeMessages(session, pushed: pushed)
                for datagram in (try? session.feedback(nowMicros: SessionCase.now)) ?? [] {
                    try FuzzRun.check(!datagram.isEmpty && datagram.count <= 1 << 16, "a \(datagram.count)-byte feedback datagram")
                }
            }

            mutating func takeMessages(_ session: RemoteRdSession, pushed: Int) throws {
                while let message = try? session.popMessage() {
                    let size: Int = switch message {
                    case let .control(bytes), let .datagram(bytes), let .bulk(bytes): bytes.count
                    }
                    try FuzzRun.check(size <= pushed, "a \(size)-byte message from \(pushed) bytes")
                    try FuzzRun.check(messages.count <= pushed, "more messages than bytes pushed")
                    if case let .control(json) = message, case let .service(_, body)? = try? RemoteRdControl.parse(json) {
                        _ = RemoteRdSurfaceStreamChange(body)
                    }
                    messages.append(message)
                }
            }
        }

        static func streamFrame(_ payload: Data, control: Bool) throws -> [UInt8] {
            [UInt8](try RemoteRdCore.streamFrame(payload, control: control))
        }

        /// The 16-byte `cmux.rd/1` datagram header on stream 0 (cmux-rd-proto datagram.rs).
        static func header(flags: UInt8, kind: UInt8, frame: UInt32, index: UInt16, count: UInt16, sequence: UInt16) -> [UInt8] {
            var out: [UInt8] = [(1 << 4) | flags, kind]
            let stream: UInt16 = 0
            let parity: UInt16 = 0
            withUnsafeBytes(of: stream.littleEndian) { out.append(contentsOf: $0) }
            withUnsafeBytes(of: frame.littleEndian) { out.append(contentsOf: $0) }
            withUnsafeBytes(of: index.littleEndian) { out.append(contentsOf: $0) }
            withUnsafeBytes(of: count.littleEndian) { out.append(contentsOf: $0) }
            withUnsafeBytes(of: parity.littleEndian) { out.append(contentsOf: $0) }
            withUnsafeBytes(of: sequence.littleEndian) { out.append(contentsOf: $0) }
            return out
        }

        /// The video datagrams of `frame`: its body (`u32 au_len, u64 t_capture_us, u32 ref_frame`, the
        /// access unit; frame.rs) in shards of `length` bytes, the last one zero-padded when there are several.
        static func shards(of frame: SentFrame, reference: UInt32, length: Int, sequence: inout UInt16) -> [[UInt8]] {
            var body: [UInt8] = []
            withUnsafeBytes(of: UInt32(frame.accessUnit.count).littleEndian) { body.append(contentsOf: $0) }
            withUnsafeBytes(of: frame.tCaptureMicros.littleEndian) { body.append(contentsOf: $0) }
            withUnsafeBytes(of: reference.littleEndian) { body.append(contentsOf: $0) }
            body += frame.accessUnit
            let count = max(1, (body.count + length - 1) / length)
            if count > 1 { body += [UInt8](repeating: 0, count: count * length - body.count) }
            var out: [[UInt8]] = []
            for index in 0..<count {
                sequence &+= 1
                let shard = body[(index * length)..<min((index + 1) * length, body.count)]
                out.append(header(flags: frame.flags, kind: videoKind, frame: frame.frame, index: UInt16(index), count: UInt16(count), sequence: sequence) + shard)
            }
            return out
        }
    }
}
