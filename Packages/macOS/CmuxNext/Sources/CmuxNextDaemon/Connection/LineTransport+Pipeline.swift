import CmuxNextWakeups
import Foundation
import CmuxNextCompat

extension LineTransport {
    /// What the reader does with a request's response.
    enum Waiter {
        case reply(cmd: String, ReplySlot)
        case discard(cmd: String, onError: (@Sendable (DaemonError) -> Void)?)
        /// Its deadline passed; the late reply is dropped. The id stays in
        /// `order` so an id-less error still maps to the right request.
        case expired(cmd: String)

        var cmd: String {
            switch self {
            case .reply(let cmd, _), .discard(let cmd, _), .expired(let cmd): cmd
            }
        }

        /// How its reply line counts: read when a request waits for it, or when it is the error of one
        /// sent without waiting; otherwise dropped.
        func replyKind(ok: Bool) -> DaemonWireStats.FrameKind {
            switch self {
            case .reply: .reply
            case .discard: ok ? .droppedReply : .reply
            case .expired: .droppedReply
            }
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
        case waiting(CheckedContinuation<LineTransport.Response, any Error>?)
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
        let resolved: (waiter: CheckedContinuation<LineTransport.Response, any Error>?, span: LineTransport.RequestSpan?)? =
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
        try await withCheckedThrowingContinuation { continuation in
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
        var ids: [UInt64] = []
        for line in lines {
            let slot = ReplySlot()
            slots.append(slot)
            let submitted = submit(.reply(cmd: line.cmd.wire, slot)) { id in
                let data = try line.body(id)
                // Each slot ends its own `daemon.request` slice, as ``request(cmd:timeout:_:)``'s does.
                beginRequestSpan(line.cmd, id: id, slot: slot)
                return data
            }
            // A failed submit resolved the slot already.
            if case .success(let id) = submitted { ids.append(id) }
        }
        let timer = DemandTimer(owner: "LineTransport.deadline")
        defer { timer.cancel() }
        if let timeout, !ids.isEmpty {
            timer.schedule(after: timeout) { [weak self, ids] in
                for id in ids { self?.expire(id: id, after: timeout) }
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
}

extension PipelinedLine {
    init<R: DaemonRequest>(_ request: R) {
        self.init(cmd: R.commandName) { id in try WireCoding.encodeRequest(request, id: id) }
    }
}
