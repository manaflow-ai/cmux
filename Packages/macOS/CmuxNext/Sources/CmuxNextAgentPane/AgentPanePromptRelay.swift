import Foundation
import os

/// The relay's side of ``AgentPanePromptJournal`` for one connection of ``AgentPaneTransport``: a
/// person's prompt is recorded before it goes and forgotten at acpmux's acknowledgement or reply;
/// a prompt left over from an earlier run goes again, once, right after the connection's first
/// frame and person proof. Only a connection to this Mac's acpmux has one; its daemon is named by
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

    /// The connection ended: `byDaemon` when the daemon's side closed it and the page was told
    /// (its prompts are the page's again, with Retry); otherwise its prompts are left over for the
    /// next connection.
    func ended(byDaemon: Bool) {
        journal.connectionEnded(owner: owner, byDaemon: byDaemon)
    }

    /// Records the decided prompt in `box` on disk before it goes (a prompt with no promptId gets
    /// one here, so acpmux can tell its resend from a new prompt), forgotten at the reply to
    /// `relayID`. A promptId this daemon got from the relay before is the pane's Retry: it goes
    /// marked `resend` (which the page may not send), so acpmux also finds a first copy in the
    /// chat's log, which outlives a daemon restart, and runs it at most once. Returns its
    /// promptId, or nil when it is not kept. Throws ``AgentPaneTransportError/promptNotKept`` when
    /// its record could not be written: the journal keeps nothing of it, the frame must not go, and
    /// it is not marked sent (its Retry goes as a first send unless an earlier send of it went).
    @concurrent func record(_ box: AgentPaneTransport.FrameBox, ids: AcpmuxRequestIds,
                            relayID: Int?) async throws(AgentPaneTransportError) -> String? {
        guard let text = box.encoded(id: nil),
              var object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              var params = object["params"] as? [String: Any], let session = params["sessionId"] as? String else { return nil }
        var meta = params["_meta"] as? [String: Any] ?? [:]
        var acpmux = meta["acpmux"] as? [String: Any] ?? [:]
        let named = acpmux["promptId"] as? String ?? ""
        let promptId = named.isEmpty ? UUID().uuidString.lowercased() : named
        var rewrite = named.isEmpty
        acpmux["promptId"] = promptId
        let kept: Bool?
        do {
            kept = try journal.record(daemon: daemon, promptId: promptId, owner: owner) { sentBefore in
                if sentBefore {
                    acpmux["resend"] = true
                    rewrite = true
                }
                if rewrite {
                    meta["acpmux"] = acpmux
                    params["_meta"] = meta
                    object["params"] = params
                    guard let rewritten = AcpmuxRequestIds.encode(object), box.replace(withJSON: rewritten) else { return nil }
                }
                guard let paramsText = AcpmuxRequestIds.encode(params) else { return nil }
                return AgentPanePromptJournal.Entry(daemon: daemon, sessionId: session, promptId: promptId,
                                                    params: paramsText, at: journal.now())
            }
        } catch {
            Self.logger.error("agent pane prompt not sent: its journal record was not written")
            throw .promptNotKept
        }
        guard kept == true else { return nil }
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
    /// and its own promptId, under a host request id (its reply never reaches the page).
    @concurrent func resend(socket: AcpmuxPaneSocket, ids: AcpmuxRequestIds) async {
        var sent = 0
        let claimed = journal.claimLeftovers(daemon: daemon, owner: owner)
        for (index, entry) in claimed.enumerated() {
            let id = ids.hostID()
            guard let text = Self.resendFrame(entry, id: id) else {
                forget(entry.promptId)
                continue
            }
            let forget = forget
            ids.whenAnswered(id) { forget(entry.promptId) }
            if let error = socket.send(text) {
                ids.cancel(id)
                journal.unclaim(Array(claimed[index...]), owner: owner)
                Self.logger.error("unacknowledged prompt not resent: \(error.rawValue, privacy: .public)")
                break
            }
            sent += 1
        }
        if sent > 0 { Self.logger.info("resent \(sent, privacy: .public) unacknowledged prompt(s)") }
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
