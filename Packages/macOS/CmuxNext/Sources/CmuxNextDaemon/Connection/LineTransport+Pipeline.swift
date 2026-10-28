import Foundation
import CmuxNextCompat
import class CmuxSafeConcurrency.OnceContinuation
import func CmuxSafeConcurrency.withOnceThrowingContinuation

extension LineTransport {
    /// What the reader does with a request's response.
    enum Waiter {
        case reply(cmd: String, ReplySlot)
        case discard(cmd: String, onError: (@Sendable (DaemonError) -> Void)?)
        /// The connection's decode lane hands the reply, or the closing thread the connection's end, to this
        /// handler (``send(cmd:onReply:_:)``).
        case handled(cmd: String, ReplyHandler)
        /// Its deadline passed; the late reply is dropped. The id stays
        /// pending so an id-less error still maps to the right request.
        case expired(cmd: String)

        var cmd: String {
            switch self {
            case .reply(let cmd, _), .discard(let cmd, _), .handled(let cmd, _), .expired(let cmd): cmd
            }
        }

        /// How its reply line counts: read when a request waits for it, or when it is the error of one
        /// sent without waiting; otherwise dropped.
        func replyKind(ok: Bool) -> DaemonWireStats.FrameKind {
            switch self {
            case .reply, .handled: .reply
            case .discard: ok ? .droppedReply : .reply
            case .expired: .droppedReply
            }
        }

        /// Where an error reply goes: the waiting slot, the handler, or the discarded request's `onError`;
        /// nil when nobody reads it, so the reader does not parse its error fields.
        var failure: ((DaemonError) -> Void)? {
            switch self {
            case .reply(_, let slot): { slot.resolve(.failure($0)) }
            case .handled(_, let handler): { handler(.failure($0)) }
            case .discard(_, let onError): onError
            case .expired: nil
            }
        }
    }

    /// Runs on the connection's decode lane with a request's reply (inline on the reader while that lane is idle),
    /// or on the closing thread with the connection's end; once, and never under the transport's locks.
    typealias ReplyHandler = @Sendable (Result<Response, DaemonError>) -> Void

    /// An `ok:true` response line plus the number of events routed before it
    /// on this transport. Every event with index <= `eventBarrier` was
    /// emitted before the command's result, so a snapshot supersedes it.
    struct Response: Sendable {
        var line: Data
        var eventBarrier: UInt64
        /// The connection's recorder: decoding the line counts there
        /// (`WireCoding.decodeResponse(_:from:)` given the response).
        var recorder: DaemonWireStats.Recorder?
    }

    /// A request whose deadline passed: what its `timedOut` error and its timing need.
    struct Expired {
        var cmd: String
        var slot: ReplySlot
        var sent: DaemonWireStats.RequestStamp?
        var timeout: Duration
    }

    static func closedError(_ reason: TransportCloseReason) -> DaemonError {
        switch reason {
        case .closedByClient: .connectionClosed(reason: "closed by client")
        case .daemonShutdown: .daemonShutdown
        case .lost(let detail): .connectionClosed(reason: detail)
        }
    }
}

/// One request for `LineTransport.pipeline`: its command name (for errors
/// and its trace slice) and its encoder, which receives the allocated id.
struct PipelinedLine {
    var cmd: DaemonCommandName
    var body: (UInt64) throws -> Data
}

/// A request's reply, resolved once by the reader thread (the response),
/// the deadline (`timedOut`) or the transport closing. The awaiting side may
/// come before or after the resolution. The resolution ends the request's
/// `daemon.request` slice, so the slice measures the request's own reply even
/// while its awaiter is still behind an earlier request's.
final class ReplySlot: Sendable {
    private enum Phase {
        case waiting(OnceContinuation<LineTransport.Response, any Error>?)
        case done(Result<LineTransport.Response, any Error>)
    }

    private struct State {
        var phase = Phase.waiting(nil)
        /// The request's open slice, ended by the resolution.
        var span: LineTransport.RequestSpan?
    }

    private let state = Mutex(State())

    /// Hands the slot its request's open slice; the resolution ends it (at once when the slot resolved already).
    func arm(_ span: LineTransport.RequestSpan) {
        let done: Result<LineTransport.Response, any Error>? = state.withLock { state in
            guard case .done(let result) = state.phase else {
                state.span = span
                return nil
            }
            return result
        }
        if let done { span.end(LineTransport.RequestOutcome(done)) }
    }

    /// First resolution wins; later ones are ignored.
    func resolve(_ result: Result<LineTransport.Response, any Error>) {
        let resolved: (waiter: OnceContinuation<LineTransport.Response, any Error>?, span: LineTransport.RequestSpan?)? =
            state.withLock { state in
                guard case .waiting(let waiter) = state.phase else { return nil }
                state.phase = .done(result)
                defer { state.span = nil }
                return (waiter: waiter, span: state.span)
            }
        guard let resolved else { return }
        resolved.span?.end(LineTransport.RequestOutcome(result))
        resolved.waiter?.resume(with: result)
    }

    func value() async throws -> LineTransport.Response {
        try await withOnceThrowingContinuation { (continuation: OnceContinuation<LineTransport.Response, any Error>) in
            let done: Result<LineTransport.Response, any Error>? = state.withLock { state in
                switch state.phase {
                case .done(let result): return result
                case .waiting: state.phase = .waiting(continuation); return nil
                }
            }
            if let done { continuation.resume(with: done) }
        }
    }
}

extension LineTransport {
    /// Writes every request now, back to back in this order, then awaits
    /// their replies: requests that do not depend on each other's answers
    /// cost one daemon round trip together instead of one each. The daemon
    /// starts commands serially per connection, so they run in this order.
    /// One deadline covers the group; each result is that request's reply
    /// or error, in request order.
    func pipeline(_ lines: [PipelinedLine], timeout: Duration?) async -> [Result<Response, any Error>] {
        var slots: [ReplySlot] = []
        // One deadline for the group: its requests expire in one fire of the connection's timer.
        let groupDeadline = timeout.map { self.deadline(after: $0) }
        for line in lines {
            let slot = ReplySlot()
            slots.append(slot)
            // A failed submit resolves the slot itself.
            submit(.reply(cmd: line.cmd.wire, slot), deadline: groupDeadline) { id in
                let data = try line.body(id)
                // Each slot ends its own `daemon.request` slice, as ``request(cmd:timeout:_:)``'s does.
                beginRequestSpan(line.cmd, id: id, slot: slot)
                return data
            }
        }
        var results: [Result<Response, any Error>] = []
        for slot in slots {
            do {
                results.append(.success(try await slot.value()))
            } catch {
                results.append(.failure(error))
            }
        }
        return results
    }

    /// Sends one command without waiting; `onReply` gets its reply (`ok` or an error) on the reader thread, or
    /// the connection's end. A request refused before it was registered (a closed connection) returns its error
    /// here and never reaches `onReply`. No deadline: the reply or the connection's end resolves it. Writes reach the socket in
    /// call order.
    @discardableResult
    func send(cmd: DaemonCommandName, onReply: @escaping ReplyHandler, _ body: (UInt64) throws -> Data) -> Result<UInt64, any Error> {
        submit(.handled(cmd: cmd.wire, onReply), body)
    }
}

extension PipelinedLine {
    init<R: DaemonRequest>(_ request: R) {
        self.init(cmd: R.commandName) { id in try WireCoding.encodeRequest(request, id: id) }
    }
}
