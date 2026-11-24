import CmuxConnectivityTelemetry
import CmuxMobileTransport
import Foundation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "acpmux")

/// A prompt's turn and a Stop, each with a bound (Leo 2026-11-24: "I feel like there are often
/// these like dead hang loops ... endless freezes, these soft locks if not hard locks").
///
/// A `session/prompt` is answered when its turn ends, which may be hours (an approval waits on the
/// person), so its reply had a 24 h allowance and nothing else: a Mac that lost the turn without
/// answering (the agent died, the reply was dropped on a channel that stayed open) left the
/// prompt's write in flight for a day, and with it every stall on that channel was read as "slow
/// behind a write" and never recovered. Now the wait is bounded by silence instead of length:
/// any record or session change for the chat resets it, and after ``promptSilence`` of none the
/// Mac is asked what became of the turn.
extension AcpmuxHub {
    nonisolated static let defaultPromptSilence: Duration = .seconds(60)
    nonisolated static let defaultStopBound: Duration = .seconds(10)

    /// What the Mac says of a session's turn (`_acpmux/info`, `waitLogs: false`: answered at once).
    enum TurnState: Equatable {
        /// Running, or waiting on the person (an approval, a question): the turn goes on.
        case running
        /// Not running: the turn is over, `lastSeq` the session's newest record.
        case ended(lastSeq: Int)
        /// The Mac didn't answer within ``stallAfter`` (or refused the read).
        case unknown
    }

    func turnState(_ sessionID: String, on connection: AcpmuxConnection? = nil) async -> TurnState {
        guard let connection = connection ?? self.connection else { return .unknown }
        let params: JSONValue = .object(["sessionId": .string(sessionID), "waitLogs": .bool(false)])
        guard let info = try? await connection.request("_acpmux/info", params, timeout: stallAfter),
              let session = AcpmuxSession(info) else { return .unknown }
        switch session.summaryStatus {
        case .running, .waiting: return .running
        default: return .ended(lastSeq: session.lastSeq)
        }
    }

    /// The answer to prompt `id` on `connection`, bounded by silence. Each ``promptSilence`` with
    /// no record or session change for `sessionID`, the Mac is asked about the turn: still running,
    /// the wait goes on; over, the chat reads on from its last record and the wait ends (null);
    /// no answer, the channel is recovered, which fails this reply as closed (the chat holds the
    /// prompt and sends it again as a resend, which acpmux runs at most once).
    func awaitTurn(_ connection: AcpmuxConnection, id: Int, sessionID: String) async throws -> JSONValue {
        let watch = Task { @MainActor [weak self] in
            var seen = self?.turnProgress[sessionID, default: 0] ?? 0
            while !Task.isCancelled {
                guard let silence = self?.promptSilence, let clock = self?.steadyClock else { return }
                try? await clock.sleep(for: silence)
                guard !Task.isCancelled, let self else { return }
                let progress = turnProgress[sessionID, default: 0]
                if progress != seen {
                    seen = progress
                    continue
                }
                let state = await turnState(sessionID, on: connection)
                guard !Task.isCancelled else { return }
                switch state {
                case .running:
                    seen = turnProgress[sessionID, default: 0]
                case .ended:
                    log.notice("prompt of \(sessionID, privacy: .public) unanswered past its turn's end: ending its wait")
                    ConnectivityTelemetry.shared.record(.hub, "prompt_silent", outcome: .success,
                                                        fields: ["state": .text("ended")])
                    refillSources(sessionID)
                    await connection.abandon(id)
                    return
                case .unknown:
                    log.notice("prompt of \(sessionID, privacy: .public) silent and the Mac didn't answer: recovering the channel")
                    ConnectivityTelemetry.shared.record(.hub, "prompt_silent", outcome: .failure,
                                                        fields: ["state": .text("unknown")])
                    await recover(from: connection, why: "prompt_silent", method: "session/prompt")
                    return
                }
            }
        }
        defer { watch.cancel() }
        return try await connection.reply(to: id)
    }

    /// `session/prompt` for a caller with no chat open (a push reply, a New Task's first message):
    /// written once (never retried), its answer bounded as ``awaitTurn(_:id:sessionID:)`` does.
    public func prompt(_ params: JSONValue) async throws -> JSONValue {
        let (connection, id) = try await submit("session/prompt", params)
        return try await awaitTurn(connection, id: id, sessionID: params["sessionId"]?.stringValue ?? "")
    }
}
