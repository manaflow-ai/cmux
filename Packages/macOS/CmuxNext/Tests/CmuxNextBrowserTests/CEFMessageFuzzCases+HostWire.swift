#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
import CmuxFuzzSupport
@testable import CmuxNextBrowser
import Foundation

/// The Chromium host wire cases of ``CEFMessageFuzzTests`` (p10-stability-180): input frames, control frames
/// and the mirror they fill (ChromiumHost/src/chromium_host_wire.h, chromium_host_control.h,
/// client/remote_shim_mirror.h).
extension CEFMessageFuzzCases {
    typealias Field = ChromiumHostControlMessage.Field

    /// Every frame of `data` from the start: each re-encodes to its bytes, until the rest needs more or is refused.
    static func hostFrames(_ data: Data) throws {
        let bytes = [UInt8](data)
        var offset = 0
        while offset <= bytes.count {
            let rest = bytes[offset...]
            switch ChromiumHostFrame.decode(rest) {
            case .frame(let frame, let consumed):
                try FuzzRun.check(consumed == ChromiumHostFrame.headerSize + frame.payload.count && consumed <= rest.count,
                                  "a frame took \(consumed) of \(rest.count) bytes for a \(frame.payload.count)-byte payload")
                try FuzzRun.check(frame.encoded() == Array(rest.prefix(consumed)), "a frame does not re-encode to its bytes")
                _ = (frame.kind, frame.text, frame.wheelFields, frame.inputPresentedFields, frame.reportsInputPresented, frame.ctlSeq)
                offset += consumed
            case .needMore:
                let length = rest.count < ChromiumHostFrame.headerSize ? 0 : littleEndian(rest, at: 4)
                try FuzzRun.check(rest.count < ChromiumHostFrame.headerSize + length, "a whole frame reads as needing more")
                return
            case .invalid:
                try FuzzRun.check(littleEndian(rest, at: 4) > ChromiumHostFrame.maxPayload, "a frame within the bound was refused")
                return
            }
        }
    }

    /// Up to 5 frames of random kinds, fields and payloads.
    static func frames(_ rng: inout FuzzRNG) -> [ChromiumHostFrame] {
        (0..<(1 + rng.below(5))).map { _ -> ChromiumHostFrame in
            var frame = ChromiumHostFrame(rawKind: rng.oneIn(3) ? UInt32(truncatingIfNeeded: rng.next()) : UInt32(1 + rng.below(110)))
            frame.v = (0..<6).map { _ in Int32(truncatingIfNeeded: rng.next()) }
            frame.flags = rng.next()
            frame.t0 = rng.next()
            frame.t1 = rng.next()
            frame.ch = UInt16(truncatingIfNeeded: rng.next())
            frame.unmod = UInt16(truncatingIfNeeded: rng.next())
            frame.seq = UInt32(truncatingIfNeeded: rng.next())
            frame.payload = [UInt8](rng.bytes(rng.oneIn(16) ? 4_096 : 64))
            return frame
        }
    }

    /// Frames sent as one stream and read in random pieces, the reader keeping what needs more.
    static func hostStream(_ rng: inout FuzzRNG) throws {
        let sent = frames(&rng)
        let stream = sent.flatMap { $0.encoded() }
        var buffer: [UInt8] = []
        var received: [ChromiumHostFrame] = []
        var at = 0
        while at < stream.count {
            let piece = min(stream.count - at, 1 + rng.below(96))
            buffer += stream[at..<(at + piece)]
            at += piece
            while case .frame(let frame, let consumed) = ChromiumHostFrame.decode(buffer[...]) {
                received.append(frame)
                buffer.removeFirst(consumed)
            }
        }
        try FuzzRun.check(buffer.isEmpty && received == sent, "sent \(sent.count) frames, read \(received.count), \(buffer.count) bytes left")
    }

    /// Every control frame of `data` from the start, with no descriptors received.
    static func controlFrames(_ data: Data) throws {
        let bytes = [UInt8](data)
        let mirror = ChromiumHostMirror()
        var offset = 0
        while offset <= bytes.count {
            var descriptors: [Int32] = []
            let rest = bytes[offset...]
            guard case .frame(let message, let consumed) = ChromiumHostControlMessage.decode(rest, fds: &descriptors) else { break }
            try FuzzRun.check(message.fds.isEmpty && descriptors.isEmpty, "a frame holds descriptors nobody sent")
            try FuzzRun.check(consumed >= ChromiumHostControlMessage.headerSize && consumed <= rest.count,
                              "a frame took \(consumed) of \(rest.count) bytes")
            if !message.fields.contains(where: isNaN) {
                try FuzzRun.check(message.encoded() == Array(rest.prefix(consumed)), "a control frame does not re-encode to its bytes")
            }
            _ = (message.sharedFieldIndices(), ChromiumHostMirror.PendingKey.changed(by: message))
            if ChromiumHostMirror.takes(message) { _ = mirror.apply(message) }
            offset += consumed
        }
        try FuzzRun.check(mirror.pendingCount == 0, "a received frame marked a key pending")
    }

    static func value(_ rng: inout FuzzRNG) -> ChromiumHostControlMessage.Value {
        switch rng.below(5) {
        case 0: return .i32(Int32(truncatingIfNeeded: rng.next()))
        case 1: return .i64(Int64(bitPattern: rng.next()))
        case 2: return .f64(rng.oneIn(8) ? Double(bitPattern: rng.next()) : rng.double(in: -1e9...1e9))
        case 3: return .bytes([UInt8](rng.bytes(64)))
        default: return .str(FuzzJSON.randomString(&rng, limit: 24))
        }
    }

    static func fields(_ rng: inout FuzzRNG) -> [Field] {
        (0..<rng.below(5)).map { _ in Field(tag: rng.byte(), value: value(&rng)) }
    }

    static func controlMessage(_ rng: inout FuzzRNG) -> ChromiumHostControlMessage {
        ChromiumHostControlMessage(op: rng.oneIn(3) ? ChromiumHostOp.mirrorOp : UInt16(truncatingIfNeeded: rng.next()),
                                   token: UInt32(truncatingIfNeeded: rng.next()), isReply: rng.bool(), fields: fields(&rng))
    }

    /// An `EncodeFields` body of random fields, damaged one time in six.
    static func fieldsBody(_ rng: inout FuzzRNG) -> [UInt8] {
        let encoded = ChromiumHostControlMessage(op: 0, fields: fields(&rng)).encoded() ?? []
        var body = [UInt8](encoded.dropFirst(ChromiumHostControlMessage.headerSize))
        if rng.oneIn(6) { body = [UInt8](FuzzMutator().mutate(Data(body), using: &rng)) }
        return body
    }

    /// A MIRROR or ACK frame near the valid shape, applied to `mirror`: taken exactly when well formed.
    static func mirrorFrame(_ rng: inout FuzzRNG, into mirror: ChromiumHostMirror) throws {
        let op = rng.oneIn(8) ? Int32(truncatingIfNeeded: rng.next()) : Int32(1 + rng.below(12))
        var fields = [Field(tag: 1, value: rng.oneIn(10) ? value(&rng) : .i32(op)), Field(tag: 2, value: .bytes(fieldsBody(&rng)))]
        if !rng.oneIn(4) { fields.append(Field(tag: 3, value: rng.oneIn(10) ? value(&rng) : .bytes(fieldsBody(&rng)))) }
        if rng.oneIn(10) { fields.removeAll() }
        let message = ChromiumHostControlMessage(op: rng.oneIn(6) ? ChromiumHostOp.ackOp : ChromiumHostOp.mirrorOp,
                                                 token: UInt32(rng.below(3)), isReply: rng.oneIn(6), fields: fields)
        let taken = mirror.apply(message)
        try FuzzRun.check(taken == wellFormed(message), "the mirror \(taken ? "took" : "refused") \(message)")
        try FuzzRun.check(mirror.pendingCount == 0, "a received frame marked a key pending")
        guard case .bytes(let key)? = message.fields.dropFirst().first?.value, let decoded = ChromiumHostMirror.decodeFields(key),
              !decoded.contains(where: isNaN) else { return }
        // A body that decodes re-encodes to itself.
        let again = (ChromiumHostControlMessage(op: 0, fields: decoded).encoded() ?? []).dropFirst(ChromiumHostControlMessage.headerSize)
        try FuzzRun.check(Array(again) == key, "a mirror key body does not re-encode to its bytes")
    }

    /// ChromiumHostMirror.apply's rule, from remote_shim_mirror.h.
    static func wellFormed(_ message: ChromiumHostControlMessage) -> Bool {
        if message.op == ChromiumHostOp.ackOp {
            return message.isReply && message.token != 0 && message.fields.isEmpty && message.fds.isEmpty
        }
        let fields = message.fields
        guard message.op == ChromiumHostOp.mirrorOp, !message.isReply, message.fds.isEmpty, fields.count == 2 || fields.count == 3,
              case .i32(let op) = fields[0].value, (1...ChromiumHostMirror.maxExportOp).contains(op),
              case .bytes(let key) = fields[1].value, ChromiumHostMirror.decodeFields(key) != nil else { return false }
        guard fields.count == 3 else { return true }
        guard case .bytes(let value) = fields[2].value else { return false }
        return ChromiumHostMirror.decodeFields(value) != nil
    }

    static func isNaN(_ field: Field) -> Bool {
        if case .f64(let number) = field.value { return number.isNaN }
        return false
    }

    /// The little-endian u32 at `offset` of `bytes` (at least `offset + 4` long).
    static func littleEndian(_ bytes: ArraySlice<UInt8>, at offset: Int) -> Int {
        (0..<4).reduce(0) { $0 | Int(bytes[bytes.startIndex + offset + $1]) << (8 * $1) }
    }
}
#endif
