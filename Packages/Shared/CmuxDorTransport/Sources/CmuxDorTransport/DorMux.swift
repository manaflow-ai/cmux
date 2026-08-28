// Plaintext mux framing inside sealed session payloads.
//
// One sealed leg payload = exactly one mux op:
//   [u8 op][u32be streamID][rest]
//
// Streams are bidirectional byte streams opened by either side (initiator
// allocates odd ids, responder even) whose first op is `open` carrying the
// lane descriptor JSON. Flow control is credit-based per stream: each side
// may have at most `initialWindow` un-consumed bytes in flight; the receiver
// returns `credit` ops as the app actually reads.

import Foundation

enum DorMuxOp: UInt8, Sendable {
    case open = 0x01
    case data = 0x02
    case eof = 0x03
    case reset = 0x04
    case credit = 0x05
    /// Responder → initiator inside the sealed channel: the session id from
    /// hs2 is confirmed under the session keys, completing admission.
    case admit = 0x10
    case sessionClose = 0x13
    case ping = 0x20
    case pong = 0x21
}

struct DorMuxFrame: Sendable, Equatable {
    let op: DorMuxOp
    let streamID: UInt32
    let payload: Data

    init(op: DorMuxOp, streamID: UInt32, payload: Data = Data()) {
        self.op = op
        self.streamID = streamID
        self.payload = payload
    }

    func encoded() -> Data {
        var data = Data(capacity: 5 + payload.count)
        data.append(op.rawValue)
        withUnsafeBytes(of: streamID.bigEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    static func decode(_ data: Data) -> DorMuxFrame? {
        guard data.count >= 5 else { return nil }
        let bytes = [UInt8](data.prefix(5))
        guard let op = DorMuxOp(rawValue: bytes[0]) else { return nil }
        let streamID = bytes[1...4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return DorMuxFrame(op: op, streamID: streamID, payload: data.subdata(in: 5..<data.count))
    }
}

enum DorMuxLimits {
    /// Un-consumed bytes one side may have in flight per stream. Bounds the
    /// leg resend buffer under a fast producer (artifact downloads) and the
    /// receive buffer under a slow consumer.
    static let initialWindow = 1024 * 1024
    /// Replenish once at least this much has been consumed (credit batching).
    static let creditBatch = 256 * 1024
    /// Stream data chunk cap: with the mux header (5), seal overhead (29) and
    /// leg header (14) this stays far below the relay's 120 KiB spill cap.
    static let chunkBytes = 64 * 1024
}

extension DorMuxFrame {
    static func creditPayload(_ bytes: Int) -> Data {
        var data = Data()
        withUnsafeBytes(of: UInt32(clamping: bytes).bigEndian) { data.append(contentsOf: $0) }
        return data
    }

    var creditBytes: Int? {
        guard op == .credit, payload.count == 4 else { return nil }
        return Int(payload.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
    }
}
