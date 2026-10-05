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
            }
        }
        return batch
    }

    /// One frame of a pass (see ``drain()``).
    nonisolated static func analyzeOne(_ text: String, _ snapshot: Snapshot, socket: AcpmuxPaneSocket,
                                       ids: AcpmuxRequestIds) -> Analysis {
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
        let error = sendNow(box, relayID: relayID, socket: socket)
        // A large frame is freed here, not on the main thread when its step ends.
        box.object = [:]
        return error
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
    nonisolated static func refuse(_ decision: AcpmuxPaneMethods.Decision, socket: AcpmuxPaneSocket, rootRequested: Bool = false) -> Step {
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
        guard let method = object["method"] as? String, AcpmuxPaneMethods.sessionScoped.contains(method) else { return nil }
        let session = (object["params"] as? [String: Any])?["sessionId"] as? String
        guard let session, sessions.contains(session) else {
            return .refuse(.sessionNotInPane, method: method, requestID: object["id"].flatMap(AcpmuxPaneMethods.rawID))
        }
        return nil
    }
}
