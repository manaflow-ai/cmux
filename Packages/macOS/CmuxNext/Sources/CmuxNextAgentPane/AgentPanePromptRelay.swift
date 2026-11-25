import CmuxNextWakeups
import Foundation
import os

/// The relay's side of ``AgentPanePromptJournal`` for one connection of ``AgentPaneTransport``: a
/// person's prompt is recorded before it goes and forgotten at acpmux's acknowledgement or reply;
/// a prompt left over from an earlier run goes again right after the connection's first frame and
/// person proof, and again after each "not now" from acpmux (a just-restarted or busy daemon), until
/// acpmux takes it, refuses it for good, or the journal lets it age out. Only a connection to this Mac's acpmux has one; its daemon is named by
/// its unix socket, which outlives a daemon restart.
nonisolated struct AgentPanePromptRelay: Sendable {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.prompt-journal")
    let journal: AgentPanePromptJournal
    let daemon: String
    /// This connection, in the journal (never reused, unlike an object's address).
    let owner = UUID()

    init?(_ connection: AcpmuxConnection, journal: AgentPanePromptJournal?) {
        guard connection.remote == nil, let journal, let daemon = connection.socketPath, !daemon.isEmpty else { return nil }
        self.journal = journal
        self.daemon = daemon
    }

    /// acpmux acknowledged or answered prompt `promptId` (or it was never sent).
    var forget: @Sendable (String) -> Void {
        { [journal, daemon] promptId in journal.forget(daemon: daemon, promptId: promptId) }
    }

    /// The connection ended: its prompts are left over for the next connection.
    func ended() {
        journal.connectionEnded(owner: owner)
    }

    /// Records the decided prompt in `box` on disk before it goes (a prompt with no promptId gets
    /// one here, so acpmux can tell its resend from a new prompt), forgotten at the reply to
    /// `relayID`. A promptId this daemon got from the relay before is the pane's Retry: it goes
    /// marked `resend` (which the page may not send), so acpmux also finds a first copy in the
    /// chat's log, which outlives a daemon restart, and runs it at most once. Returns its
    /// promptId, or nil when it is not kept.
    @concurrent func record(_ box: AgentPaneTransport.FrameBox, ids: AcpmuxRequestIds, relayID: Int?) async -> String? {
        guard let text = box.encoded(id: nil),
              var object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              var params = object["params"] as? [String: Any], let session = params["sessionId"] as? String else { return nil }
        var meta = params["_meta"] as? [String: Any] ?? [:]
        var acpmux = meta["acpmux"] as? [String: Any] ?? [:]
        let named = acpmux["promptId"] as? String ?? ""
        let promptId = named.isEmpty ? UUID().uuidString.lowercased() : named
        var rewrite = named.isEmpty
        acpmux["promptId"] = promptId
        if journal.sendsAgain(daemon: daemon, promptId: promptId) {
            acpmux["resend"] = true
            rewrite = true
        }
        if rewrite {
            meta["acpmux"] = acpmux
            params["_meta"] = meta
            object["params"] = params
            guard let rewritten = AcpmuxRequestIds.encode(object), box.replace(withJSON: rewritten) else { return nil }
        }
        guard let paramsText = AcpmuxRequestIds.encode(params),
              journal.record(AgentPanePromptJournal.Entry(daemon: daemon, sessionId: session, promptId: promptId,
                                                          params: paramsText, at: journal.now()),
                             owner: owner) else { return nil }
        let forget = forget
        if let relayID { ids.whenAnswered(relayID) { forget(promptId) } }
        return promptId
    }

    /// The recorded prompt did not go (a stale connection, a send error): the step that says so.
    @discardableResult
    @concurrent func withdraw(_ promptId: String?, relayID: Int?, ids: AcpmuxRequestIds) async -> AgentPaneTransport.Step {
        if let relayID { ids.cancel(relayID) }
        if let promptId { forget(promptId) }
        return .stop(.staleConnection)
    }

    /// Sends each left-over prompt of this daemon as it was recorded, with `_meta.acpmux.resend`
    /// and its own promptId, under a host request id (its reply never reaches the page). The
    /// journal is the outbox: a prompt stays in it until acpmux takes it or refuses it for good. A
    /// refusal that only says "not now" (a daemon still starting after a restart, a busy
    /// connection, the host's own wait) sends it again on this connection after a backoff, and a
    /// closed connection leaves it for the next. Before, any answer forgot it, so a prompt a
    /// just-restarted daemon refused was lost and its row said "Not sent" after a fixed 10 s
    /// (Leo, 2026-11-25: "native.timed_out ... Failed: 11017 ms after sending").
    /// Each outcome goes to the page as `_cmux/prompt_resend` (``Outcome``), so its row waits
    /// as long as the outbox still works on it and says why only when it gives up.
    @concurrent func resend(socket: AcpmuxPaneSocket, ids: AcpmuxRequestIds) async {
        var sent = 0
        let claimed = journal.claimLeftovers(daemon: daemon, owner: owner)
        for (index, entry) in claimed.enumerated() {
            guard send(entry, attempt: 0, socket: socket, ids: ids) else {
                journal.unclaim(Array(claimed[index...]), owner: owner)
                break
            }
            sent += 1
        }
        if sent > 0 { Self.logger.info("resent \(sent, privacy: .public) unacknowledged prompt(s)") }
    }

    /// What became of a resent prompt, as the page hears it.
    nonisolated enum Outcome: String, Sendable {
        /// On the wire to acpmux.
        case sent
        /// acpmux took it.
        case accepted
        /// acpmux said not now: it goes again after `retryInMs`.
        case retrying
        /// acpmux refused it for good: its row fails with acpmux's words.
        case refused
    }

    /// The backoff before resend attempt `attempt` after a "not now": 1 s, 2 s, 4 s ... up to 30 s.
    static func backoff(attempt: Int) -> Duration {
        var spacing = spacing(attempt: attempt)
        return spacing.next()
    }

    /// The ``Backoff`` that waits `backoff(attempt:)` next: unjittered, so the wait the page is told
    /// (`retryInMs`) is the one the outbox waits.
    static func spacing(attempt: Int) -> Backoff {
        var spacing = Backoff(initial: .seconds(1), maximum: .seconds(30), jitter: 0)
        for _ in 0..<min(max(attempt, 0), 6) { _ = spacing.next() }
        return spacing
    }

    /// A refusal that says "not now", never "no": the daemon or host will take it later.
    static func transient(_ reply: AcpmuxRequestIds.Reply) -> Bool {
        if reply.ok { return false }
        if reply.origin == "native" { return true }
        let words = [reply.reason, reply.code].compactMap { $0?.lowercased() }
        let markers = ["busy", "unproven", "starting", "not_ready", "notready", "restarting", "unavailable",
                       "loading", "timed_out", "timeout", "not_connected", "draining", "retry"]
        return words.contains { word in markers.contains { word.contains($0) } }
    }

    /// Puts `entry` on the wire as attempt `attempt`; false when the socket refused the frame.
    @discardableResult
    func send(_ entry: AgentPanePromptJournal.Entry, attempt: Int, socket: AcpmuxPaneSocket,
              ids: AcpmuxRequestIds) -> Bool {
        let id = ids.hostID()
        guard let text = Self.resendFrame(entry, id: id) else {
            forget(entry.promptId)
            return true
        }
        let relay = self
        ids.whenReply(id) { reply in
            relay.answered(entry, reply: reply, attempt: attempt, socket: socket, ids: ids)
        }
        if let error = socket.send(text) {
            ids.cancel(id)
            Self.logger.error("unacknowledged prompt not resent: \(error.rawValue, privacy: .public)")
            return false
        }
        Self.tell(socket, entry, .sent, attempt: attempt)
        return true
    }

    private func answered(_ entry: AgentPanePromptJournal.Entry, reply: AcpmuxRequestIds.Reply, attempt: Int,
                          socket: AcpmuxPaneSocket, ids: AcpmuxRequestIds) {
        if reply.ok {
            forget(entry.promptId)
            return Self.tell(socket, entry, .accepted, attempt: attempt)
        }
        guard Self.transient(reply), journal.keeps(daemon: daemon, promptId: entry.promptId) else {
            forget(entry.promptId)
            Self.logger.notice("resent prompt refused: \(reply.code ?? "-", privacy: .public) \(reply.reason ?? "-", privacy: .public)")
            return Self.tell(socket, entry, .refused, attempt: attempt, reply: reply)
        }
        let wait = Self.backoff(attempt: attempt)
        Self.tell(socket, entry, .retrying, attempt: attempt, reply: reply, retryIn: wait)
        let relay = self
        Task.detached(priority: .utility) {
            var spacing = Self.spacing(attempt: attempt)
            try? await spacing.wait(owner: "agent-pane.prompt-outbox")  // concurrency-allow: Backoff.wait is an async clock sleep in a detached task, never a blocking wait
            // A closed connection left it over for the next one (``ended()``); one acpmux took
            // meanwhile (its `_acpmux/prompt_accepted`) is no longer kept.
            guard !socket.isClosed, relay.journal.keeps(daemon: relay.daemon, promptId: entry.promptId) else { return }
            relay.send(entry, attempt: attempt + 1, socket: socket, ids: ids)
        }
    }

    /// `_cmux/prompt_resend` to the page, through the socket's own inbound path (in order with the
    /// daemon's frames): `{sessionId, promptId, state, attempt, retryInMs?, code?, reason?, message?}`.
    static func tell(_ socket: AcpmuxPaneSocket, _ entry: AgentPanePromptJournal.Entry, _ outcome: Outcome,
                     attempt: Int, reply: AcpmuxRequestIds.Reply? = nil, retryIn: Duration? = nil) {
        guard let text = notice(entry, outcome, attempt: attempt, reply: reply, retryIn: retryIn) else { return }
        socket.receiveLocalReply(text)
    }

    static func notice(_ entry: AgentPanePromptJournal.Entry, _ outcome: Outcome, attempt: Int,
                       reply: AcpmuxRequestIds.Reply? = nil, retryIn: Duration? = nil) -> String? {
        var params: [String: Any] = [
            "sessionId": entry.sessionId, "promptId": entry.promptId, "state": outcome.rawValue, "attempt": attempt,
        ]
        if let retryIn {
            let (seconds, attoseconds) = retryIn.components
            params["retryInMs"] = Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
        }
        if let code = reply?.code { params["code"] = code }
        if let reason = reply?.reason { params["reason"] = reason }
        if let message = reply?.message { params["message"] = String(message.prefix(1000)) }
        return AcpmuxRequestIds.encode(["jsonrpc": "2.0", "method": "_cmux/prompt_resend", "params": params])
    }

    /// The `session/prompt` request for a recorded prompt: its params, marked as a resend. A steer
    /// goes as a plain prompt: the turn it was meant for ended with the app.
    static func resendFrame(_ entry: AgentPanePromptJournal.Entry, id: Int) -> String? {
        guard var params = (try? JSONSerialization.jsonObject(with: Data(entry.params.utf8))) as? [String: Any],
              params["sessionId"] as? String == entry.sessionId else { return nil }
        var meta = params["_meta"] as? [String: Any] ?? [:]
        var acpmux = meta["acpmux"] as? [String: Any] ?? [:]
        guard acpmux["promptId"] as? String == entry.promptId else { return nil }
        acpmux["resend"] = true
        for key in ["steer", "interrupt", "steerOnly"] { acpmux[key] = nil }
        meta["acpmux"] = acpmux
        params["_meta"] = meta
        return AcpmuxRequestIds.encode(["jsonrpc": "2.0", "id": id, "method": "session/prompt", "params": params])
    }
}
