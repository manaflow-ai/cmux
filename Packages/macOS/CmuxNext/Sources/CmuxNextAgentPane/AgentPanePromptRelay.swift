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
    /// and its own promptId, under a host request id (its reply never reaches the page). A prompt
    /// that names `@computer-use` while Computer Use is known and not ready (`computerUse`) is held:
    /// it stays in the journal, unsent, and goes at a later call once Computer Use is ready
    /// (``AgentPaneComputerUse`` calls ``AgentPaneTransport/replayHeldPrompts()`` then), so a prompt
    /// admitted before a disconnect never runs after Computer Use was turned off (review round 3 of #48024).
    @concurrent func resend(socket: AcpmuxPaneSocket, ids: AcpmuxRequestIds, computerUse: AgentPaneComputerUseState? = nil) async {
        var sent = 0
        let claimed = journal.claimLeftovers(daemon: daemon, owner: owner) { Self.holds($0, computerUse: computerUse) }
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

    /// Whether the journal holds `entry` back from a resend: its text names `@computer-use`
    /// (``AgentPaneComputerUseState/isNamed(in:)``) while Computer Use is known and not ready.
    static func holds(_ entry: AgentPanePromptJournal.Entry, computerUse: AgentPaneComputerUseState?) -> Bool {
        guard let computerUse, computerUse != .ready else { return false }
        return AgentPaneComputerUseState.isNamed(in: promptText(entry))
    }

    /// The text blocks of a recorded prompt (`params.prompt`'s `{type: "text", text}`), one per line.
    static func promptText(_ entry: AgentPanePromptJournal.Entry) -> String {
        guard let params = (try? JSONSerialization.jsonObject(with: Data(entry.params.utf8))) as? [String: Any],
              let blocks = params["prompt"] as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
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

extension AgentPaneTransport {
    /// Replays the journal's left-over prompts on this connection again: Computer Use turned ready, so a prompt that
    /// names `@computer-use` and was held at the connection's first replay goes now (``AgentPaneComputerUse/set(_:)``).
    /// Only once the connection's person proof and trust barrier went (``hostSendsOpen``), and only on an open local
    /// connection; a prompt another replay claimed meanwhile is not sent twice (the journal holds one claim each).
    func replayHeldPrompts() {
        guard hostSendsOpen, let socket, !socket.isClosed, let relay = promptRelay, let ids = requestIds else { return }
        let state = computerUse?.state
        // task-owner: one journal replay on this connection; a closed one claims nothing (its relay ended).
        Task { await relay.resend(socket: socket, ids: ids, computerUse: state) }
    }

    /// Tells this connection's acpmux Computer Use's state on this Mac (`_acpmux/computer_use_state {state}`, null while
    /// unknown) under a host request id, whose reply never reaches the page. acpmux takes it from the app's own local
    /// connection only (LocalApp) and holds a prompt that names `@computer-use` while the state is known and not ready.
    /// Sent once the connection is up (``hostSendsOpen``) and on every change (``AgentPaneComputerUse/set(_:)``); never
    /// on a remote wire, whose daemon is another machine's. A daemon too old for the method answers method-not-found:
    /// dropped, as every host reply.
    func tellComputerUseState() {
        guard hostSendsOpen, !remoteWire, let computerUse, let socket, !socket.isClosed, let ids = requestIds,
              let text = Self.computerUseStateFrame(computerUse.state, id: ids.hostID()) else { return }
        if let error = socket.send(text) { Self.logger.debug("agent pane transport: computer use state not sent: \(error.rawValue, privacy: .public)") }
    }

    /// The `_acpmux/computer_use_state` request for `state`.
    nonisolated static func computerUseStateFrame(_ state: AgentPaneComputerUseState?, id: Int) -> String? {
        AcpmuxRequestIds.encode(["jsonrpc": "2.0", "id": id, "method": "_acpmux/computer_use_state",
                                 "params": ["state": state.map { $0.rawValue as Any } ?? NSNull()]])
    }
}
