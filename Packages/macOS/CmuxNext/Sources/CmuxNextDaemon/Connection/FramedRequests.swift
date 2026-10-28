import CmuxNextIPC
import Foundation

/// How one connection sends typed v12 commands once `ipc-frames-v2` is granted (p05-ipc-092;
/// cmux-tui/spec/transports.md, "Binary frames").
///
/// A REQUEST frame carries the request's JSON line without its `\n`; its header names the method by the id
/// and priority of the ``MethodTable`` and the request by the low 32 bits of the connection's request id. The
/// daemon routes on the header alone and answers with a REPLY or ERROR frame whose body is the JSON line it
/// writes today (cmux-tui frame_dispatch.rs). Mojo sends a method the same way: a header with the method's
/// ordinal and request id in front of the serialized params, the reply matched by that id
/// (mojo/public/cpp/bindings/lib/message_internal.h, `MessageHeaderV1`).
///
/// Only methods the daemon listed in `identify {revisions}` `framed_methods` go as frames, from a table of the
/// same schema digest (``WireNegotiation``); every other command stays a line. A method is never tried on a
/// frame to see whether the daemon serves it: its refusal would come back after the requests written behind
/// it had run, and the retry would run it out of order.
struct FramedRequests: Sendable {
    /// REQUEST, REPLY and ERROR (cmux-ipc `FrameKind`).
    static let requestKind: UInt8 = 16
    static let replyKind: UInt8 = 17
    static let errorKind: UInt8 = 18

    let table: MethodTable
    /// The methods the daemon answers on frames (`framed_methods`).
    let served: Set<MethodID>
    /// The daemon reads a REQUEST frame's trace flow (it offered ``WireNegotiation/requestFlowCapability``).
    let readsFlow: Bool

    init(table: MethodTable, served: Set<MethodID>, readsFlow: Bool = false) {
        self.table = table
        self.served = served
        self.readsFlow = readsFlow
    }

    /// The method to frame `cmd` as, or nil to send it as a line: a JSON v12 command of the table that the
    /// daemon answers on frames, runs on the connection's control sequence, and whose body fits its bound.
    func method(for cmd: String, bodyBytes: Int) -> MethodAttributes? {
        guard let id = table.v12ID(named: cmd), served.contains(id), let method = table.v12(id),
              method.payload == .json, !method.streamScoped else { return nil }
        let bound = min(method.maxBytes ?? FrameHeader.maxPayloadCap, FrameHeader.maxPayloadCap)
        return bodyBytes <= Int(truncatingIfNeeded: bound) ? method : nil
    }

    /// The call flag of a REQUEST that carries its trace flow (cmux-ipc `CallFlags::FLOW`).
    static let flowFlag: UInt8 = 1 << 2
    /// The bytes of that flow id, little endian, in front of the body (frame_dispatch.rs `FLOW_ID_BYTES`).
    static let flowIDBytes = 8

    /// Whether a REQUEST frame of a `bodyBytes` body has room for the flow id within the frame's payload bound.
    static func hasRoomForFlow(bodyBytes: Int) -> Bool {
        bodyBytes <= Int(truncatingIfNeeded: FrameHeader.maxPayloadCap) - flowIDBytes
    }

    /// Whether a REQUEST frame of a `bodyBytes` body to this daemon carries its flow: the daemon reads it and
    /// the frame has room.
    func carriesFlow(bodyBytes: Int) -> Bool {
        readsFlow && Self.hasRoomForFlow(bodyBytes: bodyBytes)
    }

    /// One REQUEST frame on stream 0: the 16-byte header (cmux-ipc frame.rs `Aux::Call`: request id u32,
    /// method id u16, the table's priority, the flags), then the payload. With a nonzero `flow` (the request's
    /// `daemon.request` flow, LineTransport+RequestTrace.swift) the flags are ``flowFlag`` and the payload is the
    /// flow id, 8 bytes little endian, then `body` (p05-ipc-180): the daemon records the flow at the request's
    /// arrival and at its reply. With none, or a body too large to carry it, there are no flags and the payload
    /// is `body`. Pass a flow only to a daemon that reads it (``carriesFlow(bodyBytes:)``).
    static func requestFrame(_ body: Data, requestID: UInt64, method: MethodAttributes, flow: UInt64 = 0) -> Data {
        let traced = flow != 0 && hasRoomForFlow(bodyBytes: body.count)
        let length = body.count + (traced ? flowIDBytes : 0)
        var frame = Data(capacity: FrameHeader.byteCount + length)
        frame.append(FrameHeader.magic)
        frame.append(requestKind)
        append(UInt16.zero, to: &frame)
        append(UInt32(truncatingIfNeeded: length), to: &frame)
        append(UInt32(truncatingIfNeeded: requestID), to: &frame)
        append(method.id.rawValue, to: &frame)
        frame.append(method.priority.rawValue)
        frame.append(traced ? flowFlag : 0)
        if traced { append(flow, to: &frame) }
        frame.append(body)
        return frame
    }

    /// The call fields of a REPLY or ERROR frame's header.
    struct Call: Equatable {
        var requestID: UInt32
        var methodID: MethodID
    }

    /// The call fields of `header` (aux bytes 8-13, little endian).
    static func call(of header: FrameHeader) -> Call {
        let raw = header.encode()
        let aux = raw.dropFirst(8)
        let requestID = aux.prefix(4).reversed().reduce(UInt32.zero) { $0 << 8 | UInt32(truncatingIfNeeded: $1) }
        let methodID = aux.dropFirst(4).prefix(2).reversed().reduce(UInt16.zero) { $0 << 8 | UInt16(truncatingIfNeeded: $1) }
        return Call(requestID: requestID, methodID: MethodID(rawValue: methodID))
    }

    /// The connection request id whose low 32 bits are `low`: the latest one allocated before `next`. Frame ids
    /// are the low half of the connection's u64 ids, so they wrap after 2^32 requests; an id stays unique while
    /// fewer than 2^32 requests are in flight, which the daemon checks (frame_dispatch.rs `admit`).
    static func requestID(low: UInt32, next: UInt64) -> UInt64 {
        let high: UInt64 = 0xFFFF_FFFF_0000_0000
        let candidate = (next & high) | UInt64(truncatingIfNeeded: low)
        return candidate < next ? candidate : candidate &- (1 << 32)
    }

    /// Appends `value` little endian.
    private static func append<Value: FixedWidthInteger & UnsignedInteger>(_ value: Value, to data: inout Data) {
        for shift in stride(from: 0, to: Value.bitWidth, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }
}
