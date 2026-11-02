import Foundation
import os

/// The off-main part of a page frame's check (``AgentPaneTransport/drain()``): no main-actor state.
extension AgentPaneTransport {
    /// The off-main pass over the line's frames (see ``drain()``).
    @concurrent nonisolated static func analyze(_ texts: [String], _ start: Snapshot, socket: AcpmuxPaneSocket,
                                                ids: AcpmuxRequestIds) async -> Batch {
        var batch = Batch()
        var snapshot = start
        for text in texts {
            switch analyzeOne(text, snapshot, socket: socket, ids: ids) {
            case .sent(nil):
                batch.outcomes.append(.sent)
                if snapshot.isFirst {
                    batch.firstSent = true
                    snapshot.isFirst = false
                    snapshot.localAppToken = nil
                }
            case .sent(let error?):
                batch.outcomes.append(.stop(error))
                return batch
            case .refuse(let decision, let spend?):
                batch.next = .spend(spend, decision)
                return batch
            case .refuse(let decision, nil):
                let step = refuse(decision, socket: socket)
                batch.outcomes.append(step)
                if case .stop = step { return batch }
            case .decide(let facts, let box):
                batch.next = .decide(facts, box)
                return batch
            case .status(_, let relayID, let path):
                guard socket.statusRead.begin() else {
                    // A refresh may overlap the initial read. Refuse just this request through
                    // the bounded inbound path; never open another connection or close the pane.
                    socket.receiveLocalReply(Self.statusError(relayID: relayID))
                    batch.outcomes.append(.sent)
                    continue
                }
                // task-owner: one read per socket, ending within two seconds; its slot is released
                // on every exit. A closed socket drops the result through the normal inbound path.
                Task.detached(priority: .utility) {
                    defer { socket.statusRead.end() }
                    let result = try? await AcpmuxStatusClient.call(socketPath: path, method: "_acpmux/status",
                                                                   deadline: .seconds(2))
                    let reply = result.flatMap {
                        AcpmuxRequestIds.encode(["jsonrpc": "2.0", "id": relayID, "result": $0])
                    } ?? Self.statusError(relayID: relayID)
                    // The regular inbound path bounds queued bytes/frames, resolves the relay id,
                    // and applies the status reply shape before anything reaches the page.
                    socket.receiveLocalReply(reply)
                }
                batch.outcomes.append(.sent)
            }
        }
        return batch
    }

    nonisolated private static func statusError(relayID: Int) -> String {
        "{\"jsonrpc\":\"2.0\",\"id\":\(relayID),\"error\":{\"code\":-32000,\"message\":\"status unavailable\"}}"
    }

    /// What the rules that need no main-actor state make of one frame: refused (a ticket in it, if
    /// any, is to be spent), or the checked frame and its facts. No socket and no request ids. The
    /// Rust copy of these rules (cmux-agent-pane-policy `check_frame`) runs the cases in its
    /// tests/cases/check.json; no Swift test reads that file, so a rule here needs its own Swift
    /// test (the transport tests, for example `AgentPaneForkRelayTests`).
    nonisolated enum Checked: Sendable {
        case refuse(AcpmuxPaneMethods.Decision, spend: String?)
        case frame(Facts, FrameBox)
    }

    /// One frame of a pass (see ``drain()``).
    nonisolated static func analyzeOne(_ text: String, _ snapshot: Snapshot, socket: AcpmuxPaneSocket,
                                       ids: AcpmuxRequestIds) -> Analysis {
        let facts: Facts
        let box: FrameBox
        switch checkOne(text, snapshot) {
        case .refuse(let decision, let spend): return .refuse(decision, spend: spend)
        case .frame(let checked, let frame):
            facts = checked
            box = frame
        }
        let method = facts.method
        let pageID = facts.pageID
        guard facts.free else { return .decide(facts, box) }
        // Free: nothing on the main actor decides it, so it goes out from here, in the same order.
        // A start or open is counted before it goes, or refused while a Sandboxed send runs.
        guard socket.sendingPageFrame(method: method) else {
            return .refuse(.refuse(.methodRefused, method: method, requestID: pageID), spend: nil)
        }
        var relayID: Int?
        if let pageID {
            guard let next = ids.begin(pageID: pageID, method: method ?? "") else {
                socket.pageFrameNotSent(method: method)
                return .refuse(.refuse(.requestIdInFlight, method: nil, requestID: nil), spend: nil)
            }
            relayID = next
        }
        if method == "_acpmux/status", let pageID, let relayID, let path = snapshot.socketPath,
           !snapshot.remoteWire {
            return .status(pageID: pageID, relayID: relayID, path: path)
        }
        if !snapshot.isFirst, let method { snapshot.sessions.sent(method: method, id: pageID) }
        let error = sendNow(box, relayID: relayID, socket: socket)
        if error != nil { socket.pageFrameNotSent(method: method) }
        if error != nil, let relayID { ids.cancel(relayID) }
        if error == .outboundOverflow { socket.close(code: 1008, reason: "outbound overflow", error: error) }
        return .sent(error)
    }

    /// The off-main rules on one frame, in order (see ``Checked``).
    nonisolated static func checkOne(_ text: String, _ snapshot: Snapshot) -> Checked {
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
        // Answers go only to a pending question, keyed by its items and bounded (the answers rule).
        if AcpmuxPaneMethods.breaksAnswersRule(object, options: snapshot.options) {
            return .refuse(.refuse(.intentInvalid, method: method, requestID: pageID), spend: carried)
        }
        // A prompt block's own _meta never reaches the harness.
        var frame = AcpmuxPaneMethods.strippingPromptMeta(object) ?? object
        var facts = Facts(isFirst: snapshot.isFirst, method: method, pageID: pageID)
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
            // A fork or handoff from a session outside the scope waits for the click's scope credit.
            if let method, AcpmuxPaneMethods.sourceScoped.contains(method), !snapshot.sessions.holdsSource(params) {
                facts.foreignSource = true
                facts.handoffId = params["handoffId"] as? String
            }
            facts.harnessEnable = method == "_acpmux/harness_enable"
            facts.startsLocalSession = method == "session/new" && !snapshot.remoteWire
        }
        if let requested = AcpmuxPaneMethods.requestedSetting(frame) {
            let value = requested.value ?? configValueText(frame)
            facts.setting = Setting(sessionId: requested.sessionId, configId: requested.configId, value: requested.value,
                                    asked: requested.configId == "mode" ? .mode(value) : .option(id: requested.configId, value: value))
        }
        // The LocalApp token goes into the first frame after every rule read the page's own frame.
        if snapshot.isFirst, let token = snapshot.localAppToken { frame = AcpmuxPaneMethods.withLocalAppToken(frame, token) }
        return .frame(facts, FrameBox(frame))
    }

    /// The folder rule on the decided frame (the disk is read here, off the main thread). The
    /// checked frame (canonical paths, a filled cwd) replaces the box's object.
    @concurrent nonisolated static func checkPaths(_ box: FrameBox, scope: AcpmuxPathPolicy.Scope) async
        -> Result<[String], AcpmuxPathPolicy.Refusal> {
        guard let text = box.encoded(id: nil) else {
            return .failure(AcpmuxPathPolicy.Refusal(error: .invalidFrame, requestID: nil, method: nil))
        }
        switch AcpmuxPathPolicy.checkNow(text, scope: scope) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let checked):
            guard box.replace(withJSON: checked.text) else {
                return .failure(AcpmuxPathPolicy.Refusal(error: .invalidFrame, requestID: nil, method: nil))
            }
            return .success(checked.gestureRootsUsed)
        }
    }

    @concurrent nonisolated static func encodeAndSend(_ box: FrameBox, relayID: Int?, socket: AcpmuxPaneSocket) async
        -> AgentPaneTransportError? {
        let error = sendNow(box, relayID: relayID, socket: socket)
        // A large frame is freed here, not on the main thread when its step ends.
        box.free()
        return error
    }

    /// The fresh serialization of the decided frame, with the relay id, to the socket; never the
    /// page's bytes.
    nonisolated static func sendNow(_ box: FrameBox, relayID: Int?, socket: AcpmuxPaneSocket) -> AgentPaneTransportError? {
        guard let text = box.encoded(id: relayID) else { return .invalidFrame }
        return socket.send(text)
    }

    /// A refused frame: answered when it is a request, the socket closed when it was the first.
    /// `detail`: acpmux's own reason, for the page to show; `reason`: why, as a code the page words.
    nonisolated static func refuse(_ decision: AcpmuxPaneMethods.Decision, socket: AcpmuxPaneSocket, detail: String? = nil,
                                   reason: String? = nil) -> Step {
        guard case .refuse(let error, let method, let requestID) = decision else { return .stop(.invalidFrame) }
        if error == .requestIdInFlight { return refuseInFlight() }
        Self.logger.error("agent pane transport refused frame error=\(error.rawValue, privacy: .public) method=\(method ?? "-", privacy: .public)")
        if error == .firstFrameNotInitialize {
            socket.close(code: 1008, reason: "first frame", error: error)
            return .stop(error)
        }
        if let requestID {
            socket.inject(AcpmuxPaneMethods.refusal(requestID: requestID, error: error, method: method, detail: detail, reason: reason))
        }
        return .refused(error)
    }

    /// No answer: the page's earlier request with this id still waits for its own.
    nonisolated static func refuseInFlight() -> Step {
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

    /// The refusal of a session-scoped frame for a session that is not this pane's.
    nonisolated static func sessionRefusal(_ object: [String: Any], sessions: AcpmuxPaneSessions) -> AcpmuxPaneMethods.Decision? {
        guard let method = object["method"] as? String else { return nil }
        let named = (object["params"] as? [String: Any])?["sessionId"]
        // A frame that may name a session and names none is not session-scoped.
        if AcpmuxPaneMethods.optionallySessionScoped.contains(method), named == nil { return nil }
        guard AcpmuxPaneMethods.sessionScoped.contains(method) || AcpmuxPaneMethods.optionallySessionScoped.contains(method)
        else { return nil }
        let session = named as? String
        // Other params that name a session must name one of the pane's too (`_acpmux/side`'s chat).
        let params = object["params"] as? [String: Any]
        let othersHeld = AcpmuxPaneMethods.scopedSessionParams[method, default: []]
            .allSatisfy { (params?[$0] as? String).map(sessions.contains) == true }
        // Ones that may name a session (an accepted offer's child): none is fine, a named one
        // (even `null`) must be the pane's.
        let optionalHeld = AcpmuxPaneMethods.optionalScopedSessionParams[method, default: []]
            .allSatisfy { params?[$0] == nil || (params?[$0] as? String).map(sessions.contains) == true }
        guard let session, sessions.contains(session), othersHeld, optionalHeld else {
            return .refuse(.sessionNotInPane, method: method, requestID: object["id"].flatMap(AcpmuxPaneMethods.rawID))
        }
        return nil
    }
}
