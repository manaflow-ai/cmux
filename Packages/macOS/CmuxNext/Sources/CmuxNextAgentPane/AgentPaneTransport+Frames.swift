import Foundation
import os
import CmuxNextCompat

/// One page frame through the relay: the off-main checks and the main-actor decisions.
extension AgentPaneTransport {
    // MARK: One page frame

    /// What the off-main work needs from the main actor: small values and thread-safe handles.
    nonisolated struct Snapshot: Sendable {
        var isFirst: Bool
        var localAppToken: String?
        var modeFields: Set<String>?
        var sessions: AcpmuxPaneSessions
        var options: AcpmuxPermissionOptions
        /// The connection is a chat on another machine (``AgentPaneTransport/remoteWire``).
        var remoteWire = false
    }

    /// What the main actor learns about a frame that needs its state: small values, never the frame.
    nonisolated struct Facts: Sendable {
        /// The connection's first frame (the main actor marks it sent).
        var isFirst = false
        var method: String?
        var pageID: String?
        /// The gesture ticket the frame carried (already stripped from it), and whether its `_meta`
        /// held anything else (R1).
        var ticket: String?
        var otherMeta = false
        var pick: AgentPaneGesturePick?
        var sessionId: String?
        var needsGesture = false
        var needsPathCheck = false
        var setting: Setting?
        /// An attach of a session that is not the pane's yet (only a gesture brings it in).
        var attachSession: String?
        /// A fork or handoff from a session outside the pane's scope (it uses the click's scope
        /// credit), and the handoff it names, if any.
        var foreignSource = false
        var handoffId: String?
        /// `_acpmux/harness_enable`: the native sheet decides it (``confirmHarnessEnable(_:)``).
        var harnessEnable = false
        /// A `session/new` on this Mac: a send's gesture goes on to its first prompt (``startCredit``).
        var startsLocalSession = false

        /// No main-actor state decides this frame: it is checked, encoded and sent in one step.
        var free: Bool {
            ticket == nil && !needsGesture && !needsPathCheck && setting == nil && attachSession == nil && !foreignSource
                && !harnessEnable && !startsLocalSession
        }
    }

    /// A mode or config option the frame sets (R2, P2), with the sheet's text.
    nonisolated struct Setting: Sendable {
        var sessionId: String?
        var configId: String
        var value: String?
        var asked: AgentPaneModeConfirmation
    }

    /// The decided frame, under its own lock. The main actor never reads it; the off-main stages
    /// of its step get only what the lock hands out: the encoded text, or a yes or no.
    nonisolated final class FrameBox: Sendable {
        private let frame: Mutex<[String: Any]>

        init(_ object: sending [String: Any]) { frame = Mutex(object) }

        /// The frame's fresh serialization, with `id` set when given; nil when it does not encode.
        func encoded(id: Int?) -> String? {
            frame.withLock { object in
                var copy = object
                if let id { copy["id"] = id }
                return AcpmuxRequestIds.encode(copy)
            }
        }

        /// Replaces the frame with the parse of `text`; false when `text` is not one JSON object.
        func replace(withJSON text: String) -> Bool {
            frame.withLock { object in
                guard let parsed = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return false }
                object = parsed
                return true
            }
        }

        /// Frees a large frame here, off the main thread.
        func free() { frame.withLock { $0 = [:] } }

        /// A string param of the frame (after the folder check made folders canonical).
        func param(_ key: String) -> String? {
            frame.withLock { (($0["params"] as? [String: Any])?[key] as? String) }
        }

        /// Adds the person's decision proof (`_meta.acpmux`) of a relayed allow.
        func setDecision(nonce: String, proof: String) {
            frame.withLock { object in
                var params = object["params"] as? [String: Any] ?? [:]
                var meta = params["_meta"] as? [String: Any] ?? [:]
                var acpmux = meta["acpmux"] as? [String: Any] ?? [:]
                acpmux["decisionNonce"] = nonce
                acpmux["personDecision"] = proof
                meta["acpmux"] = acpmux
                params["_meta"] = meta
                object["params"] = params
            }
        }

        /// Sets a string param of the frame.
        func setParam(_ key: String, _ value: String) {
            frame.withLock { object in
                var params = object["params"] as? [String: Any] ?? [:]
                params[key] = value
                object["params"] = params
            }
        }
    }

    /// What one off-main pass over the line's frames did: the results of the frames it finished,
    /// in order, whether the connection's first frame went out, and the frame that waits for the
    /// main actor (if any).
    nonisolated struct Batch: Sendable {
        var outcomes: [Step] = []
        var firstSent = false
        var next: Next?
    }

    nonisolated enum Next: Sendable {
        /// The main actor decides this frame.
        case decide(Facts, FrameBox)
        /// A refused frame whose ticket the main actor spends.
        case spend(String, AcpmuxPaneMethods.Decision)
    }

    nonisolated enum Analysis: Sendable {
        /// Refused before the main actor (a ticket in it, if any, is to be spent).
        case refuse(AcpmuxPaneMethods.Decision, spend: String?)
        /// Sent already (a free frame), or the socket's error.
        case sent(AgentPaneTransportError?)
        /// The main actor decides.
        case decide(Facts, FrameBox)
    }

    /// Drains the send line in order. Off the main thread, one pass takes every waiting frame of the
    /// connection: the duplicate check, the one parse every rule reads, the rules that need no
    /// main-actor state, the re-encode and the send. It stops at the first frame that needs the main
    /// actor (the gesture record, the sheets, the pane's sessions), which gets only small facts.
    func drain() async {
        while let entry = pending.first {
            guard !entry.frames.isEmpty else {
                finishFirst()
                continue
            }
            guard entry.connection == current, let socket, let ids = requestIds else {
                complete(.stop(.staleConnection))
                continue
            }
            var texts: [String] = []
            for waiting in pending {
                guard waiting.connection == entry.connection, texts.count < Self.framesPerPass else { break }
                texts += waiting.frames.prefix(Self.framesPerPass - texts.count)
            }
            // The page's first frame goes alone: the person proof is the connection's second request.
            let wasFirst = !sentFirst
            if wasFirst { texts = Array(texts.prefix(1)) }
            let snapshot = Snapshot(isFirst: !sentFirst, localAppToken: localAppToken, modeFields: modeFields,
                                    sessions: sessions, options: permissionOptions, remoteWire: remoteWire)
            let batch = await Self.analyze(texts, snapshot, socket: socket, ids: ids)
            if batch.firstSent {
                sentFirst = true
                localAppToken = nil
            }
            for outcome in batch.outcomes { complete(outcome) }
            switch batch.next {
            case nil:
                break
            case .spend(let ticket, let decision):
                // B2: a ticket in a refused frame is spent all the same.
                _ = gestures.redeem(ticket, connection: entry.connection, pick: nil)
                complete(Self.refuse(decision, socket: socket))
            case .decide(let facts, let box):
                complete(await decide(facts, box, connection: entry.connection, socket: socket, ids: ids))
            }
            if wasFirst, sentFirst {
                let relay = promptRelay
                await provePerson(socket: socket, ids: ids)
                if self.socket === socket { await relay?.resend(socket: socket, ids: ids) }
            }
        }
        draining = false
    }

    /// The person proof (acpmux `hub/person.rs`, cx-fcaq), sent right after the page's first frame
    /// and before any other: the HMAC of the daemon's challenge from the `initialize` reply under
    /// the key this app gave the daemon on ``socketPath``. The key itself never crosses the
    /// socket. No challenge (a remote wire, an older daemon) or no key: no proof, so the pane is
    /// not the person and the daemon refuses its allows.
    private func provePerson(socket: AcpmuxPaneSocket, ids: AcpmuxRequestIds) async {
        guard let socketPath else { return }
        guard let challenge = await socket.personChallenge() else { return }
        guard self.socket === socket else { return }
        guard let proof = AcpmuxPersonKey.proof(socketPath: socketPath, transport: .app, nonce: challenge.nonce,
                                                connection: challenge.connection) else {
            Self.logger.error("agent pane transport: no person key for this daemon; allows stay refused")
            return
        }
        let frame: [String: Any] = ["jsonrpc": "2.0", "id": ids.hostID(), "method": "_acpmux/person_prove",
                                    "params": ["proof": proof]]
        guard let data = try? JSONSerialization.data(withJSONObject: frame), let text = String(data: data, encoding: .utf8) else { return }
        if let error = socket.send(text) {
            Self.logger.error("agent pane transport: person proof not sent: \(error.rawValue, privacy: .public)")
        }
    }

    /// The most frames one off-main pass takes (so a long line still yields between passes).
    static let framesPerPass = 256

    /// The next frame's result, to its send; a send whose frames are done (or stopped) is answered.
    private func complete(_ step: Step) {
        guard let entry = pending.first else { return }
        if !entry.frames.isEmpty { entry.frames.removeFirst() }
        switch step {
        case .sent: break
        case .refused(let error): entry.firstError = entry.firstError ?? error
        case .stop(let error):
            entry.firstError = entry.firstError ?? error
            entry.frames.removeAll()
        }
        if entry.frames.isEmpty { finishFirst() }
    }

    private func finishFirst() {
        let entry = pending.removeFirst()
        entry.reply(entry.firstError)
    }

    /// The frame's paths against the pane's roots and the folders the user added.
    private func checkPathsInScope(_ box: FrameBox) async -> Result<[String], AcpmuxPathPolicy.Refusal> {
        let scope = AcpmuxPathPolicy.Scope(roots: roots(), gestureRoots: gestureRoots(), fillCwd: primaryRoot(),
                                           agentHome: agentHome(), home: homeFolder, granted: addedRoots,
                                           workspaceID: workspaceID())
        return await Self.checkPaths(box, scope: scope)
    }

    /// The main actor's part of one frame: small values only (the frame stays in its box).
    private func decide(_ facts: Facts, _ box: FrameBox, connection id: Int, socket: AcpmuxPaneSocket, ids: AcpmuxRequestIds) async -> Step {
        // A gesture the folder check below uses: a new chat's start carries it to its first prompt.
        var startGesture = false
        if facts.needsPathCheck, !remoteWire {
            var result = await checkPathsInScope(box)
            guard id == current, self.socket === socket else { return .stop(.staleConnection) }
            // A folder outside every root that the user typed: their gesture adds it as a root, at
            // once and without a sheet (Lawrence 2026-10-07, "Remove dialogues."). A folder harness
            // never: its program comes from that folder, so outside the roots it stays refused. The
            // home folder (or above it) never by a plain click either: the pane asks about it first
            // (`workspace.useFolder`, cx-nn3e), and only that answer makes it a root.
            if case .failure(let refusal) = result, refusal.error == .pathOutsideRoots, let folder = refusal.outsidePath,
               !facts.harnessEnable, !refusal.outsideIsHomeOrAbove, gestures.consume() {
                startGesture = true
                grant(folder)
                result = await checkPathsInScope(box)
                guard id == current, self.socket === socket else { return .stop(.staleConnection) }
            }
            switch result {
            case .success(let gestureRootsUsed):
                // A folder of the new tab page's scan counts only when the user picked it.
                if !gestureRootsUsed.isEmpty {
                    guard gestures.consume() else {
                        return Self.refuse(.refuse(.pathOutsideRoots, method: facts.method, requestID: facts.pageID), socket: socket)
                    }
                    startGesture = true
                    addedRoots += gestureRootsUsed.filter { !addedRoots.contains($0) }
                }
            case .failure(let refusal):
                return Self.refuse(.refuse(refusal.error, method: refusal.method, requestID: refusal.requestID), socket: socket)
            }
        }
        // The gesture rule: a ticket for its exact pick (R1: nothing else in `_meta`), else a live gesture.
        var ticketPick = false
        if !facts.isFirst {
            let granted: Bool
            if let ticket = facts.ticket {
                if facts.otherMeta {
                    _ = gestures.redeem(ticket, connection: id, pick: nil)
                    return Self.refuse(.refuse(.intentInvalid, method: facts.method, requestID: facts.pageID), socket: socket)
                }
                // B2: only set_mode, set_config_option, a prompt held for the trust answer (its
                // promptId) and a permission answer (its session, prompt and option) redeem a
                // ticket, for their exact pick, into a session of this pane. A ticket is spent even
                // when it does not match.
                let redeemed = gestures.redeem(ticket, connection: id, pick: facts.pick, sessionId: facts.sessionId)
                granted = redeemed && AgentPaneGestureIntent.methods[facts.method ?? ""] != nil
                    && facts.sessionId.map(sessions.contains) == true
                ticketPick = granted
            } else if remoteWire, facts.method == "session/new" {
                // A new chat on another machine starts only from the person's own send (cx-k21v);
                // its first prompt goes with the same gesture, after the start. A prompt a
                // person's action seeded starts it once through its seed ticket, and goes out
                // with that ticket (gap 4); a CLI, MCP or script seed has none and is refused.
                if gestures.consume() {
                    granted = true
                    startCredit.give(connection: id, at: gestures.uptime)
                } else if remoteTrustCredit.take(connection: id, now: ProcessInfo.processInfo.systemUptime,
                                                 lifetime: AgentPaneUserGestures.lifetime, dropOthers: true) == true {
                    // The person's Trust click on that machine's folder question re-runs the start
                    // it held (cx-1bhjj), as a held prompt goes after Trust on this Mac.
                    granted = true
                    startCredit.give(connection: id, at: gestures.uptime)
                } else {
                    granted = gestures.takeSeedStart()
                }
            } else {
                // The start's credit is spent by the first prompt, whatever grants it.
                let credit = facts.method == "session/prompt"
                    && startCredit.take(connection: id, now: gestures.uptime, lifetime: Self.startCreditLifetime) == true
                granted = !facts.needsGesture || (AcpmuxPaneMethods.answerAllowed(facts.method, gestures) && gestures.consume()) || credit
                // A new chat on this Mac needs no gesture, but its send's (or the folder pick's) goes with its first
                // prompt however long the start takes, past ``AgentPaneUserGestures/lifetime`` (hq#2569 item 5).
                // A folder pick that took the Send's gesture (``grantPicked(_:)``) gives it to this start.
                if facts.startsLocalSession, startGesture
                    || pickCredit.take(connection: id, now: gestures.uptime, lifetime: AgentPaneUserGestures.lifetime) == true
                    || gestures.consume() {
                    startCredit.give(connection: id, at: gestures.uptime)
                }
                if granted, facts.needsGesture, remoteWire, facts.method == "acp.trust.set" {
                    remoteTrustCredit.give(connection: id, at: ProcessInfo.processInfo.systemUptime)
                }
            }
            if !granted {
                Self.logger.info("agent pane transport gesture refused method=\(facts.method ?? "-", privacy: .public) \(self.gestures.debugDescription, privacy: .public)")
                return Self.refuse(.refuse(.gestureRequired, method: facts.method, requestID: facts.pageID), socket: socket)
            }
        }
        if let refusal = fullAccessRefusal(facts, socket: socket) { return refusal }
        // P2: a config option that is not free needs the native confirmation unless the daemon says the value
        // keeps the session asking. A mode needs only the gesture rule (Lawrence 2026-10-07: no sheet for full access).
        if let setting = facts.setting, setting.asked.needsSheet {
            let answer = await webModes(setting.sessionId, setting.configId, setting.value)
            guard id == current, self.socket === socket else { return .stop(.staleConnection) }
            let asks = answer?.freeConfigIds.contains(setting.configId) == true || answer?.asks == true
            if !asks {
                let confirmed = await confirm(setting.asked)
                guard id == current, self.socket === socket else { return .stop(.staleConnection) }
                if !confirmed { return Self.refuse(.refuse(.modeNotConfirmed, method: facts.method, requestID: facts.pageID), socket: socket) }
            }
        }
        // A folder harness: the user's Enable on the native sheet, then the prompt's sha256.
        if facts.harnessEnable {
            let answer = await confirmHarnessEnable(box)
            guard id == current, self.socket === socket else { return .stop(.staleConnection) }
            if !answer.confirmed { return Self.refuse(.refuse(.harnessNotConfirmed, method: facts.method, requestID: facts.pageID), socket: socket, detail: answer.detail, reason: answer.reason) }
        }
        // cx-0q7o: an allow for a prompt of another daemon run carries the person's decision
        // proof, made here (the key never reaches the page), when this app holds that run's key.
        // Only an allow that redeemed a ticket for this very prompt and option is signed.
        if !facts.isFirst, facts.needsGesture, facts.method == "_acpmux/permission_respond" {
            // The frame's own session: `facts.sessionId` is set only for a frame with a ticket.
            signRelayedAllow(box, sessionId: box.param("sessionId"), ticketPick: ticketPick)
        }
        // A Trust answer on another machine for the folder the person chose there by Use Home
        // Folder (a root of this pane): that machine's daemon trusts its home folder only with
        // this mark, which no page can send (known params), so one click never trusts it (cx-1bhjj).
        if remoteWire, facts.method == "acp.trust.set", let cwd = box.param("cwd"), remoteHomeChosen.contains(cwd) {
            box.setParam(RemoteAcpmuxWire.homeChosenParam, "true")
        }
        // The daemon sees only relay-owned ids; a page id is used by one request at a time.
        var relayID: Int?
        if let pageID = facts.pageID {
            let subject = facts.method == AgentPaneAgentReply.method ? box.param("sessionId") : nil
            guard let next = ids.begin(pageID: pageID, method: facts.method ?? "", subject: subject) else { return Self.refuseInFlight() }
            relayID = next
        }
        // A fork or handoff from a session outside the scope: the click's scope credit, used only
        // by a frame that goes out (every refusal above leaves it).
        if facts.foreignSource, !gestures.consumeScope() {
            if let relayID { ids.cancel(relayID) }
            Self.logger.info("agent pane transport scope refused method=\(facts.method ?? "-", privacy: .public) \(self.gestures.debugDescription, privacy: .public)")
            return Self.refuse(.refuse(.gestureRequired, method: facts.method, requestID: facts.pageID), socket: socket)
        }
        // The person's prompt is on disk before it goes, until acpmux acknowledges it.
        let relay = facts.method == "session/prompt" ? promptRelay : nil
        let journaled = await relay?.record(box, ids: ids, relayID: relayID)
        if let relay, journaled != nil, id != current || self.socket !== socket { return await relay.withdraw(journaled, relayID: relayID, ids: ids) }
        if facts.isFirst {
            sentFirst = true
            localAppToken = nil
        } else {
            noteSent(facts, relayID: relayID)
            // The switch's queued prompt goes out: the switch has ended, its tickets with it.
            // A prompt went out: a seed ticket it did not redeem and the start's credit end too.
            if facts.method == "session/prompt" {
                gestures.clearTickets(); gestures.dropSeedTicket(); startCredit.clear(); pickCredit.clear()
            }
        }
        if let error = await Self.encodeAndSend(box, relayID: relayID, socket: socket) {
            if let relayID { ids.cancel(relayID) }
            await relay?.withdraw(journaled, relayID: nil, ids: ids)
            if error == .outboundOverflow { socket.close(code: 1008, reason: "outbound overflow", error: error) }
            return .stop(error)
        }
        return .sent
    }

    /// Asks the user to confirm a mode that does not ask (the native sheet); false without one.
    func confirm(_ asked: AgentPaneModeConfirmation) async -> Bool {
        guard let requestModeConfirmation else { return false }
        let gate = confirmationGate
        guard gate.open() else { return false }
        defer { gate.close() }
        return await withCheckedContinuation { continuation in
            requestModeConfirmation(asked) { continuation.resume(returning: $0) }
        }
    }

    /// Records what a sent frame starts, or opens by the user's gesture. An attach alone adds
    /// nothing: only an attach the user made (a click in the session list) brings a session in.
    /// An attach is not a grant: it uses the click's scope-add credit, one session per click, and
    /// leaves its grant credit for the prompt the same click sends. A fork or handoff from outside
    /// the scope used that credit in ``decide(_:_:connection:socket:ids:)``; its handoff is the pane's.
    func noteSent(_ facts: Facts, relayID: Int?) {
        if let session = facts.attachSession, !sessions.contains(session), gestures.consumeScope() {
            sessions.add(session)
        }
        if let method = facts.method {
            sessions.sent(method: method, id: facts.pageID, handoff: facts.handoffId, owned: facts.foreignSource)
        }
    }
}
