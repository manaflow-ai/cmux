import Foundation
import os

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
    }

    /// What the main actor learns about a frame that needs its state: small values, never the frame.
    nonisolated struct Facts: Sendable {
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

        /// No main-actor state decides this frame: it is checked, encoded and sent in one step.
        var free: Bool {
            ticket == nil && !needsGesture && !needsPathCheck && setting == nil && attachSession == nil
        }
    }

    /// A mode or config option the frame sets (R2, P2), with the sheet's text.
    nonisolated struct Setting: Sendable {
        var sessionId: String?
        var configId: String
        var value: String?
        var asked: AgentPaneModeConfirmation
    }

    /// The decided frame. It stays off the main actor: only its step reads or changes it, one stage
    /// after another (the send line runs one frame at a time), never the main actor.
    nonisolated final class FrameBox: @unchecked Sendable {
        var object: [String: Any]
        init(_ object: [String: Any]) { self.object = object }
    }

    nonisolated enum Analysis: Sendable {
        /// Refused before the main actor (a ticket in it, if any, is to be spent).
        case refuse(AcpmuxPaneMethods.Decision, spend: String?)
        /// Sent already (a free frame), or the socket's error.
        case sent(AgentPaneTransportError?)
        /// The main actor decides.
        case decide(Facts, FrameBox)
    }

    /// One frame, in order. Off the main thread: the duplicate check, the one parse every rule
    /// reads, the rules that need no main-actor state, the re-encode and the send. On the main
    /// actor, with small values only: the gesture record, the sheets and the pane's sessions.
    func step(connection id: Int, frame text: String) async -> Step {
        guard id == current, let socket, let ids = requestIds else { return .stop(.staleConnection) }
        let snapshot = Snapshot(isFirst: !sentFirst, localAppToken: localAppToken, modeFields: modeFields,
                                sessions: sessions, options: permissionOptions)
        let analysis = await Self.analyze(text, snapshot, socket: socket, ids: ids)
        if snapshot.isFirst, case .sent(nil) = analysis {
            sentFirst = true
            localAppToken = nil
        }
        guard id == current, self.socket === socket else { return .stop(.staleConnection) }
        let facts: Facts
        let box: FrameBox
        switch analysis {
        case .sent(nil):
            return .sent
        case .sent(let error?):
            return .stop(error)
        case .refuse(let decision, let spend):
            // B2: a ticket in a refused frame is spent all the same.
            if let spend { _ = gestures.redeem(spend, connection: id, pick: nil) }
            return refuse(decision, socket: socket)
        case .decide(let found, let frame):
            facts = found
            box = frame
        }
        var rootRequested = false
        if facts.needsPathCheck {
            let scope = AcpmuxPathPolicy.Scope(roots: roots() + addedRoots, gestureRoots: gestureRoots(), fillCwd: primaryRoot())
            let result = await Self.checkPaths(box, scope: scope)
            guard id == current, self.socket === socket else { return .stop(.staleConnection) }
            switch result {
            case .success(let gestureRootsUsed):
                // A folder of the new tab page's scan counts only when the user picked it.
                if !gestureRootsUsed.isEmpty {
                    guard gestures.consume() else {
                        return refuse(.refuse(.pathOutsideRoots, method: facts.method, requestID: facts.pageID), socket: socket)
                    }
                    addedRoots += gestureRootsUsed.filter { !addedRoots.contains($0) }
                }
            case .failure(let refusal):
                if refusal.error == .pathOutsideRoots, let folder = refusal.outsidePath { rootRequested = offerRoot(folder) }
                return refuse(.refuse(refusal.error, method: refusal.method, requestID: refusal.requestID), socket: socket,
                              rootRequested: rootRequested)
            }
        }
        // The gesture rule: a ticket for its exact pick (R1: nothing else in `_meta`), else a live gesture.
        if !snapshot.isFirst {
            let granted: Bool
            if let ticket = facts.ticket {
                if facts.otherMeta {
                    _ = gestures.redeem(ticket, connection: id, pick: nil)
                    return refuse(.refuse(.intentInvalid, method: facts.method, requestID: facts.pageID), socket: socket)
                }
                // B2: only set_mode and set_config_option redeem a ticket, for their exact pick, into
                // a session of this pane. A ticket is spent even when it does not match.
                let redeemed = gestures.redeem(ticket, connection: id, pick: facts.pick)
                granted = redeemed && AgentPaneGestureIntent.methods[facts.method ?? ""] != nil
                    && facts.sessionId.map(sessions.contains) == true
            } else {
                granted = !facts.needsGesture || gestures.consume()
            }
            if !granted { return refuse(.refuse(.gestureRequired, method: facts.method, requestID: facts.pageID), socket: socket) }
        }
        // R2 and P2: a mode, or a config option that is not free, needs the user's native
        // confirmation unless the daemon says that the value keeps the session asking.
        if let setting = facts.setting {
            let answer = await webModes(setting.sessionId, setting.configId, setting.value)
            guard id == current, self.socket === socket else { return .stop(.staleConnection) }
            let asks = answer?.freeConfigIds.contains(setting.configId) == true || answer?.asks == true
            if !asks {
                let confirmed = await confirm(setting.asked)
                guard id == current, self.socket === socket else { return .stop(.staleConnection) }
                if !confirmed { return refuse(.refuse(.modeNotConfirmed, method: facts.method, requestID: facts.pageID), socket: socket) }
            }
        }
        // The daemon sees only relay-owned ids; a page id is used by one request at a time.
        var relayID: Int?
        if let pageID = facts.pageID {
            guard let next = ids.begin(pageID: pageID, method: facts.method ?? "") else { return refuseInFlight() }
            relayID = next
        }
        if snapshot.isFirst {
            sentFirst = true
            localAppToken = nil
        } else {
            noteSent(facts, relayID: relayID)
            // The switch's queued prompt goes out: the switch has ended, its tickets with it.
            if facts.method == "session/prompt" { gestures.clearTickets() }
        }
        if let error = await Self.encodeAndSend(box, relayID: relayID, socket: socket) {
            if let relayID { ids.cancel(relayID) }
            if error == .outboundOverflow { socket.close(code: 1008, reason: "outbound overflow", error: error) }
            return .stop(error)
        }
        return .sent
    }

    /// The off-main part of a frame's check (see ``step(connection:frame:)``).
    @concurrent nonisolated static func analyze(_ text: String, _ snapshot: Snapshot, socket: AcpmuxPaneSocket,
                                                         ids: AcpmuxRequestIds) async -> Analysis {
        let object: [String: Any]
        switch AcpmuxPaneMethods.decideFrame(text, isFirst: snapshot.isFirst) {
        case .failure(let refusal): return .refuse(refusal.decision, spend: nil)
        case .success(let decided): object = decided
        }
        let method = object["method"] as? String
        let pageID = object["id"].flatMap(AcpmuxPaneMethods.rawID)
        let params = object["params"] as? [String: Any] ?? [:]
        let carried = (params["_meta"] as? [String: Any])?[AcpmuxPaneMethods.gestureTicketKey] as? String
        if !snapshot.isFirst, let refusal = sessionRefusal(object, sessions: snapshot.sessions) {
            return .refuse(refusal, spend: carried)
        }
        // P1: the method's known params, and no daemon mode field outside set_mode and set_config_option.
        if AcpmuxPaneMethods.breaksParamsRule(object, modeFields: snapshot.modeFields) {
            return .refuse(.refuse(.intentInvalid, method: method, requestID: pageID), spend: carried)
        }
        // A prompt block's own _meta never reaches the harness.
        var frame = AcpmuxPaneMethods.strippingPromptMeta(object) ?? object
        var facts = Facts(method: method, pageID: pageID)
        if !snapshot.isFirst {
            let (stripped, ticket, otherMeta) = AcpmuxPaneMethods.takeGestureTicket(frame)
            frame = stripped
            facts.ticket = ticket
            facts.otherMeta = otherMeta
            if ticket != nil {
                facts.pick = AgentPaneGesturePick(method: method, params: params)
                facts.sessionId = params["sessionId"] as? String
            }
            facts.needsGesture = AcpmuxPaneMethods.needsGesture(frame, options: snapshot.options)
            facts.needsPathCheck = AcpmuxPathPolicy.needsCheck(frame)
            if method == "_acpmux/attach", let session = params["sessionId"] as? String, !snapshot.sessions.contains(session) {
                facts.attachSession = session
            }
        }
        if let requested = AcpmuxPaneMethods.requestedSetting(frame) {
            let value = requested.value ?? configValueText(frame)
            facts.setting = Setting(sessionId: requested.sessionId, configId: requested.configId, value: requested.value,
                                    asked: requested.configId == "mode" ? .mode(value) : .option(id: requested.configId, value: value))
        }
        // The LocalApp token goes into the first frame after every rule read the page's own frame.
        if snapshot.isFirst, let token = snapshot.localAppToken { frame = AcpmuxPaneMethods.withLocalAppToken(frame, token) }
        let box = FrameBox(frame)
        guard facts.free else { return .decide(facts, box) }
        // Free: nothing on the main actor decides it, so it goes out from here, in the same order.
        var relayID: Int?
        if let pageID {
            guard let next = ids.begin(pageID: pageID, method: method ?? "") else { return .refuse(.refuse(.requestIdInFlight, method: nil, requestID: nil), spend: nil) }
            relayID = next
        }
        if !snapshot.isFirst, let method, AcpmuxPaneSessions.starting.contains(method) {
            snapshot.sessions.sent(method: method, id: pageID, params: params)
        }
        let error = sendNow(box, relayID: relayID, socket: socket)
        if error != nil, let relayID { ids.cancel(relayID) }
        if error == .outboundOverflow { socket.close(code: 1008, reason: "outbound overflow", error: error) }
        return .sent(error)
    }

    /// The folder rule on the decided frame (the disk is read here, off the main thread). The
    /// checked frame (canonical paths, a filled cwd) replaces the box's object.
    @concurrent nonisolated static func checkPaths(_ box: FrameBox, scope: AcpmuxPathPolicy.Scope) async
        -> Result<[String], AcpmuxPathPolicy.Refusal> {
        guard let text = AcpmuxRequestIds.encode(box.object) else {
            return .failure(AcpmuxPathPolicy.Refusal(error: .invalidFrame, requestID: nil, method: nil))
        }
        switch AcpmuxPathPolicy.checkNow(text, scope: scope) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let checked):
            guard let object = (try? JSONSerialization.jsonObject(with: Data(checked.text.utf8))) as? [String: Any] else {
                return .failure(AcpmuxPathPolicy.Refusal(error: .invalidFrame, requestID: nil, method: nil))
            }
            box.object = object
            return .success(checked.gestureRootsUsed)
        }
    }

    @concurrent nonisolated static func encodeAndSend(_ box: FrameBox, relayID: Int?, socket: AcpmuxPaneSocket) async
        -> AgentPaneTransportError? {
        sendNow(box, relayID: relayID, socket: socket)
    }

    /// The fresh serialization of the decided frame, with the relay id, to the socket; never the
    /// page's bytes.
    nonisolated static func sendNow(_ box: FrameBox, relayID: Int?, socket: AcpmuxPaneSocket) -> AgentPaneTransportError? {
        var object = box.object
        if let relayID { object["id"] = relayID }
        guard let text = AcpmuxRequestIds.encode(object) else { return .invalidFrame }
        return socket.send(text)
    }

    /// A refused frame: answered when it is a request, the socket closed when it was the first.
    func refuse(_ decision: AcpmuxPaneMethods.Decision, socket: AcpmuxPaneSocket, rootRequested: Bool = false) -> Step {
        guard case .refuse(let error, let method, let requestID) = decision else { return .stop(.invalidFrame) }
        if error == .requestIdInFlight { return refuseInFlight() }
        Self.logger.error("agent pane transport refused frame error=\(error.rawValue, privacy: .public) method=\(method ?? "-", privacy: .public)")
        if error == .firstFrameNotInitialize {
            socket.close(code: 1008, reason: "first frame", error: error)
            return .stop(error)
        }
        if let requestID {
            socket.inject(AcpmuxPaneMethods.refusal(requestID: requestID, error: error, method: method, rootRequested: rootRequested))
        }
        return .refused(error)
    }

    /// No answer: the page's earlier request with this id still waits for its own.
    func refuseInFlight() -> Step {
        Self.logger.error("agent pane transport refused frame error=\(AgentPaneTransportError.requestIdInFlight.rawValue, privacy: .public)")
        return .refused(.requestIdInFlight)
    }

    /// A config option's value as text, for the sheet (a value that is not a string).
    nonisolated static func configValueText(_ object: [String: Any]?) -> String {
        let value = (object?["params"] as? [String: Any])?["value"]
        guard let value else { return "" }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) {
            return String(decoding: data, as: UTF8.self)
        }
        return String(describing: value)
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

    /// The refusal of a session-scoped frame for a session that is not this pane's.
    nonisolated static func sessionRefusal(_ object: [String: Any], sessions: AcpmuxPaneSessions) -> AcpmuxPaneMethods.Decision? {
        guard let method = object["method"] as? String, AcpmuxPaneMethods.sessionScoped.contains(method) else { return nil }
        let session = (object["params"] as? [String: Any])?["sessionId"] as? String
        guard let session, sessions.contains(session) else {
            return .refuse(.sessionNotInPane, method: method, requestID: object["id"].flatMap(AcpmuxPaneMethods.rawID))
        }
        return nil
    }

    /// Records what a sent frame starts, or opens by the user's gesture. An attach alone adds
    /// nothing: only an attach the user made (a click in the session list) brings a session in.
    func noteSent(_ facts: Facts, relayID: Int?) {
        if let session = facts.attachSession, !sessions.contains(session), gestures.consume() {
            sessions.add(session)
        }
        if let method = facts.method, AcpmuxPaneSessions.starting.contains(method) {
            sessions.sent(method: method, id: facts.pageID, params: [:])
        }
    }
}
