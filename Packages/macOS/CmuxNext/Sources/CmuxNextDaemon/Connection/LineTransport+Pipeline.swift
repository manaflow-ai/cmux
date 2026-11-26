import CmuxNextWakeups
import Foundation
import CmuxNextCompat

/// One request for `LineTransport.pipeline`: its command name (for errors)
/// and its encoder, which receives the allocated id.
struct PipelinedLine {
    var cmd: String
    var body: (UInt64) throws -> Data
}

/// A request's reply, resolved once by the reader thread (the response),
/// the deadline (`timedOut`) or the transport closing. The awaiting side may
/// come before or after the resolution.
final class ReplySlot: Sendable {
    private enum State {
        case waiting(CheckedContinuation<LineTransport.Response, any Error>?)
        case done(Result<LineTransport.Response, any Error>)
    }

    private let state = Mutex(State.waiting(nil))

    /// First resolution wins; later ones are ignored.
    func resolve(_ result: Result<LineTransport.Response, any Error>) {
        let waiter: CheckedContinuation<LineTransport.Response, any Error>?? = state.withLock { state in
            guard case .waiting(let waiter) = state else { return nil }
            state = .done(result)
            return .some(waiter)
        }
        if case .some(let waiter?) = waiter { waiter.resume(with: result) }
    }

    func value() async throws -> LineTransport.Response {
        try await withCheckedThrowingContinuation { continuation in
            let done: Result<LineTransport.Response, any Error>? = state.withLock { state in
                switch state {
                case .done(let result): return result
                case .waiting: state = .waiting(continuation); return nil
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
        // The lines as sent, for the slow request log's ids (``SlowRequestLog/idKeys``); empty without a log.
        var sentLines: [Data?] = []
        let sent = slowLog == nil ? 0 : uptime()
        for line in lines {
            let slot = ReplySlot()
            slots.append(slot)
            var kept: Data?
            // A failed submit resolved the slot already.
            if case .success(let id) = submit(.reply(cmd: line.cmd, slot), { id in
                let encoded = try line.body(id)
                if slowLog != nil, encoded.count <= SlowRequestLog.maxKeptLineBytes { kept = encoded }
                return encoded
            }) { ids.append(id) }
            if slowLog != nil { sentLines.append(kept) }
        }
        let timer = DemandTimer(owner: "LineTransport.deadline")
        defer { timer.cancel() }
        if let timeout, !ids.isEmpty {
            timer.schedule(after: timeout) { [weak self, ids] in
                for id in ids { self?.expire(id: id, after: timeout) }
            }
        }
        var results: [Result<Response, any Error>] = []
        for (index, slot) in slots.enumerated() {
            let result: Result<Response, any Error>
            do {
                result = .success(try await slot.value())
            } catch {
                result = .failure(error)
            }
            results.append(result)
            guard let slowLog, let line = lines.dropFirst(index).first else { continue }
            // Every line was written at `sent`; this one's reply (or failure) is here now.
            let waited = uptime() &- sent
            switch result {
            case .success(let response) where waited > SlowRequestLog.slowNanoseconds:
                slowLog.noteRequest(name: line.cmd, line: sentLines.dropFirst(index).first ?? nil, nanoseconds: waited,
                                    replyBytes: response.line.count, timeout: timeout, failure: nil)
            case .success: break
            case .failure(let error):
                slowLog.noteRequest(name: line.cmd, line: sentLines.dropFirst(index).first ?? nil, nanoseconds: waited,
                                    replyBytes: nil, timeout: timeout, failure: error)
            }
        }
        return results
    }
}

extension PipelinedLine {
    init<R: DaemonRequest>(_ request: R) {
        self.init(cmd: R.command) { id in try WireCoding.encodeRequest(request, id: id) }
    }
}
