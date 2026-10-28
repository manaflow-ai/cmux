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
///
/// A request sent as a REQUEST frame carries that flow in the frame (``FramedRequests/requestFrame(_:requestID:method:flow:)``,
/// p05-ipc-180), so the daemon writes the flow's flow-in at the arrival and its flow-out at the reply, and the
/// daemon's answer is the flow-in here, with the async id in its `arg0`: one flow app -> daemon -> app, the way a
/// Mojo message's trace id joins its send, its dispatch and its response
/// (mojo/public/cpp/bindings/lib/message.cc, `GetTraceId`). A line carries no flow, so it gets no flow-in.
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
        /// The flow its REQUEST frame carried to the daemon; 0 for a line.
        var framedFlow: UInt64 = 0

        /// Ends the slice with `result`'s outcome. The daemon's answer to a framed request (a reply or an
        /// `ok:false` error) is its flow's flow-in first; a timeout or a lost connection got no answer.
        func end(_ result: Result<Response, any Error>) {
            let name = SignpostName.daemonRequest
            if framedFlow != 0, Self.answered(result) {
                trace.flowIn(name, flow: framedFlow, arg0: asyncID)
            }
            trace.writeEnd(name: name.rawValue, categoryBit: name.traceCategory.traceBit, phase: .asyncEnd, flags: .asyncID,
                           arg0: RequestOutcome(result).rawValue, arg1: asyncID)
        }

        /// Whether the daemon answered: a reply, or its `ok:false` error.
        private static func answered(_ result: Result<Response, any Error>) -> Bool {
            guard case .failure(let error) = result else { return true }
            guard case .command? = error as? DaemonError else { return false }
            return true
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
    /// when the daemon category is off. Call it before the message is written, so no reply can resolve the slot
    /// first. `framed`: the request goes as a REQUEST frame that can carry its flow.
    ///
    /// - Returns: The flow for the frame to carry: the request's flow when it is traced and `framed`, else 0.
    func beginRequestSpan(_ name: DaemonCommandName, id: UInt64, slot: ReplySlot, framed: Bool = false) -> UInt64 {
        let asyncID = traceConnection | (id & Self.requestIDMask)
        guard trace.asyncBegin(.daemonRequest, id: asyncID, arg0: UInt64(truncatingIfNeeded: name.id)) else { return 0 }
        let flow = Self.requestFlow(seed: traceFlowSeed, requestID: id)
        trace.flowOut(.daemonRequest, flow: flow, arg0: asyncID)
        let framedFlow = framed ? flow : 0
        slot.arm(RequestSpan(trace: trace, asyncID: asyncID, framedFlow: framedFlow))
        return framedFlow
    }
}
