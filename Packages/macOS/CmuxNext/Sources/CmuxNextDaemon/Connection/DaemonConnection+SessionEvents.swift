import Foundation
import Synchronization

/// The connection's one `session.events` stream (resource API v2), the
/// source of workspace status. Opened right after `subscribe`, so its
/// snapshot is held with the other handshake events and follows
/// `.connected`. A daemon without the operation answers with an error and
/// the app shows no status.
///
/// Thread-safe: the reader thread filters lines through `admit`.
final class SessionEventsTracker: Sendable {
    /// Ends in a row without a snapshot before the stream stays closed
    /// until the next connect. A slow app gets one `gap` end and a fresh
    /// snapshot; a daemon that keeps ending the stream must not get a loop.
    static let reopenBudget = 3

    private struct State {
        var streamID: String?
        var endsWithoutSnapshot = 0
    }

    private let state = Mutex(State())

    /// A new stream id (`stream_<32 hex>`), now the only one admitted.
    /// Returns the id it replaces.
    func begin(resetBudget: Bool) -> (id: String, replaced: String?) {
        let id = "stream_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let replaced = state.withLock { state in
            defer {
                state.streamID = id
                if resetBudget { state.endsWithoutSnapshot = 0 }
            }
            return state.streamID
        }
        return (id, replaced)
    }

    /// The socket closed: its stream is gone, so the next `begin` cancels
    /// nothing.
    func forget() {
        state.withLock { $0.streamID = nil }
    }

    /// True when the reader should deliver `event`. Stream lines of another
    /// stream, stream ends, and status-less deltas (`.unknown` stream lines)
    /// are dropped here, off the main actor. `reopen` runs once per end of
    /// the current stream while the budget lasts.
    func admit(_ event: DaemonEvent, reopen: () -> Void) -> Bool {
        switch event {
        case .workspaceStatus(let change, let stream):
            return state.withLock { state in
                guard state.streamID == stream else { return false }
                if case .reset = change { state.endsWithoutSnapshot = 0 }
                return true
            }
        case .sessionEventsEnded(let stream):
            let again = state.withLock { state -> Bool in
                guard state.streamID == stream else { return false }
                state.streamID = nil
                state.endsWithoutSnapshot += 1
                return state.endsWithoutSnapshot <= Self.reopenBudget
            }
            if again { reopen() }
            return false
        case .unknown(let name, _) where name == "stream_item" || name == "stream_end":
            return false
        default:
            return true
        }
    }
}

extension DaemonConnection {
    /// `session.events` with a fresh stream id, without waiting for the
    /// reply. Cancels the stream it replaces, if any.
    static func openSessionEvents(on transport: LineTransport, tracker: SessionEventsTracker, resetBudget: Bool) {
        let (stream, replaced) = tracker.begin(resetBudget: resetBudget)
        if let replaced {
            let cancel = ["stream": JSONValue.string(replaced)]
            try? transport.sendResourceNoReply(cmd: "stream.cancel") { id in
                try ResourceRequestEnvelope(id: id, operation: "stream.cancel", params: cancel).line()
            }
        }
        let params = ["stream_id": JSONValue.string(stream)]
        try? transport.sendResourceNoReply(cmd: "session.events") { id in
            try ResourceRequestEnvelope(id: id, operation: "session.events", params: params).line()
        }
    }
}
