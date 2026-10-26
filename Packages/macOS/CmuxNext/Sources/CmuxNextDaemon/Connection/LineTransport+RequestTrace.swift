import CmuxNextSignposts
import CmuxNextTrace

/// The app side of `daemon.request` (``SignpostName/daemonRequest``, p09-observability task 025): one async
/// slice per request that waits for its reply, AB at the send and AE when the reply, the error or the timeout
/// resolves the request's ``ReplySlot`` (on the reader thread, the deadline or the close), so a pipelined
/// request's slice ends at its own reply, not at the earlier ones'. Chrome's Mojo bindings trace each message
/// they send and the response that answers it, named by the method's static name
/// (mojo/public/cpp/bindings/lib/interface_endpoint_client.cc).
///
/// The slice's async id is the connection's ``LineTransport/traceConnection`` (a ``TraceRuntime/nextAsyncScope()``
/// the process never hands out again) with the wire request id in bits 0-39, so two connections' request 1 never
/// pair, even across a reconnect. The begin's `arg0` is the ``DaemonCommandName`` id; the end's `arg0` the
/// ``RequestOutcome``. A flow-out at the send carries the request's flow (``requestFlow(seed:requestID:)``), with
/// the async id in its `arg0`.
extension LineTransport {
    /// How a traced request ended: its `daemon.request` end record's `arg0`.
    enum RequestOutcome: UInt64 {
        case reply = 0
        /// An `ok:false` answer, a failed write or a closed connection.
        case error = 1
        /// No reply within the request's deadline (`DaemonError.timedOut`).
        case timeout = 2

        init(_ result: Result<Response, any Error>) {
            switch result {
            case .success: self = .reply
            case .failure(let error):
                if case .timedOut? = error as? DaemonError { self = .timeout } else { self = .error }
            }
        }
    }

    /// The open `daemon.request` slice of one request: its begin was written, so its end is written whatever the
    /// category flags are by then.
    struct RequestSpan: Sendable {
        let trace: TraceRuntime
        let asyncID: UInt64

        func end(_ outcome: RequestOutcome) {
            let name = SignpostName.daemonRequest
            trace.writeEnd(name: name.rawValue, categoryBit: name.traceCategory.traceBit, phase: .asyncEnd, flags: .asyncID,
                           arg0: outcome.rawValue, arg1: asyncID)
        }
    }

    /// Bits 0-39 of a slice's async id: the wire request id.
    static let requestIDMask: UInt64 = (1 << 40) - 1

    /// Bits 40-63 of the async id of every slice a connection opens, from its ``TraceRuntime/nextAsyncScope()``.
    static func traceConnectionBits(scope: UInt64) -> UInt64 {
        (scope & 0xFF_FFFF) << 40
    }

    /// The FNV-1a 64 state after the 4 little-endian bytes of `pid`: ``requestFlow(seed:requestID:)``'s seed.
    static func requestFlowSeed(pid: Int32) -> UInt64 {
        fnv1a(UInt64(truncatingIfNeeded: UInt32(bitPattern: pid)), bytes: 4, from: 0xCBF2_9CE4_8422_2325)
    }

    /// The flow of request `requestID` from the process whose ``requestFlowSeed(pid:)`` is `seed`: FNV-1a 64 over
    /// the pid's 4 bytes then the request id's 8, little-endian (plans/cmux-next/chrome-parity/p09-observability.md
    /// "hash(app pid, request id)"; task 103 derives the same flow on the daemon side from LOCAL_PEERPID).
    static func requestFlow(seed: UInt64, requestID: UInt64) -> UInt64 {
        fnv1a(requestID, bytes: 8, from: seed)
    }

    private static func fnv1a(_ value: UInt64, bytes: Int, from state: UInt64) -> UInt64 {
        var hash = state, rest = value
        for _ in 0..<bytes {
            hash = (hash ^ (rest & 0xFF)) &* 0x0000_0100_0000_01B3
            rest >>= 8
        }
        return hash
    }

    /// Writes the AB and the flow-out of request `id` and hands `slot` the slice to end when it resolves; nothing
    /// when the daemon category is off. Call it before the line is written, so no reply can resolve the slot first.
    func beginRequestSpan(_ name: DaemonCommandName, id: UInt64, slot: ReplySlot) {
        let asyncID = traceConnection | (id & Self.requestIDMask)
        guard trace.asyncBegin(.daemonRequest, id: asyncID, arg0: UInt64(truncatingIfNeeded: name.id)) else { return }
        trace.flowOut(.daemonRequest, flow: Self.requestFlow(seed: traceFlowSeed, requestID: id), arg0: asyncID)
        slot.arm(RequestSpan(trace: trace, asyncID: asyncID))
    }
}
