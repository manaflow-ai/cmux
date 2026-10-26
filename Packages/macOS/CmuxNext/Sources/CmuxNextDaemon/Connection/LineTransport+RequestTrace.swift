import CmuxNextSignposts
import CmuxNextTrace

/// The app side of `daemon.request` (``SignpostName/daemonRequest``, p09-observability task 025): one async
/// slice per request that waits for its reply, AB at the send and AE at the reply, the error or the timeout.
/// Chrome's Mojo bindings trace each message they send and the response that answers it, named by the
/// method's static name (mojo/public/cpp/bindings/lib/interface_endpoint_client.cc).
///
/// The slice's async id is this connection's ``LineTransport/traceConnection`` with the wire request id in
/// bits 0-39, so two connections' request 1 never pair, and task 103 derives the request's flow from it.
/// The begin's `arg0` is the ``DaemonCommandName`` id; the end's `arg0` the ``RequestOutcome``.
extension LineTransport {
    /// How a traced request ended: its `daemon.request` end record's `arg0`.
    enum RequestOutcome: UInt64 {
        case reply = 0
        /// An `ok:false` answer, a failed write or a closed connection.
        case error = 1
        /// No reply within the request's deadline (`DaemonError.timedOut`).
        case timeout = 2

        init(_ error: any Error) {
            if case .timedOut? = error as? DaemonError { self = .timeout } else { self = .error }
        }
    }

    /// The open `daemon.request` slice of one request: its begin was written.
    struct RequestSpan {
        let asyncID: UInt64
    }

    /// Bits 0-39 of a slice's async id: the wire request id.
    static let requestIDMask: UInt64 = (1 << 40) - 1

    /// Bits 40-63 of the async id of every slice a connection on `descriptor` opens: the descriptor is unique
    /// among the process's open connections.
    static func traceConnectionBits(descriptor: Int32) -> UInt64 {
        UInt64(truncatingIfNeeded: UInt32(bitPattern: descriptor) & 0xFF_FFFF) << 40
    }

    /// The typed name of `cmd` when the daemon category records, nil (and no lookup) when it is off. Call it
    /// before the socket lock.
    func requestCommand(_ cmd: String) -> DaemonCommandName? {
        trace.isEnabled(categoryBit: SignpostName.daemonRequest.traceCategory.traceBit) ? DaemonCommandName(wire: cmd) : nil
    }

    /// Writes the AB of request `id`; nil when `command` is nil or the category turned off since.
    func beginRequestSpan(_ command: DaemonCommandName?, id: UInt64) -> RequestSpan? {
        guard let command else { return nil }
        let asyncID = traceConnection | (id & Self.requestIDMask)
        return trace.asyncBegin(.daemonRequest, id: asyncID, arg0: UInt64(truncatingIfNeeded: command.id)) ? RequestSpan(asyncID: asyncID) : nil
    }

    /// Writes the AE of a begin that ``beginRequestSpan(_:id:)`` wrote, whatever the category flags are now: a
    /// written begin always gets its end, and an unwritten one never does.
    func endRequestSpan(_ span: RequestSpan?, _ outcome: RequestOutcome) {
        guard let span else { return }
        let name = SignpostName.daemonRequest
        trace.writeEnd(name: name.rawValue, categoryBit: name.traceCategory.traceBit, phase: .asyncEnd, flags: .asyncID,
                       arg0: outcome.rawValue, arg1: span.asyncID)
    }
}
