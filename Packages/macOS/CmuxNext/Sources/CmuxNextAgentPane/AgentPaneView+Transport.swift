public import AppKit
import CmuxNextDesign
import CmuxNextPages
import WebKit

extension AgentPaneView {
    func refreshQuestionKeyBinding() {
        guard let page else { return }
        guard page.window != nil, !page.isHiddenOrHasHiddenAncestor else { return }
        guard let session = model.sessionId, let connection = model.transport.connection else {
            if questionKeyBinding != nil { page.bindQuestionKeyTargets([]) { _ in } }
            questionKeyBinding = nil
            model.transport.gestures.recordQuestionReturn(false)
            return
        }
        let contexts = model.transport.decisions.questions(session: session)
        let binding = QuestionKeyBinding(connection: connection, session: session, contexts: contexts)
        let targets = contexts.keys.map {
            PageQuestionKeyTarget(sessionID: session, permissionID: $0)
        }
        // The cache describes the requested binding, not the async install's outcome. A failed
        // install or navigation can revoke the channel while native pending state is unchanged.
        guard questionKeyBinding != binding || !page.hasQuestionKeyTargets(targets) else { return }
        model.transport.gestures.recordQuestionReturn(false)
        page.bindQuestionKeyTargets([]) { _ in }
        let bound = page.bindQuestionKeyTargets(targets) { [weak self, weak page] snapshot in
            guard let self, let page else { return }
            let requestID = "question-key-" + UUID().uuidString
            guard self.model.transport.beginQuestionKeyReply(connection: connection, requestID: requestID,
                                                              target: snapshot.target) else { return }
            guard self.model.sessionId == snapshot.target.sessionID,
                  self.model.transport.connection == connection,
                  let boundContext = binding.contexts[snapshot.target.permissionID],
                  let context = self.model.transport.decisions.context(session: snapshot.target.sessionID,
                                                                                permission: snapshot.target.permissionID),
                  context == boundContext,
                  context.isQuestion, let witness = self.model.transport.gestures.questionReturnWitness,
                  let reply = try? JSONSerialization.jsonObject(with: Data(snapshot.replyJSON.utf8)) as? [String: Any],
                  let option = reply["optionId"] as? String,
                  let answers = reply["answers"] as? [String: Any] else {
                self.model.transport.rejectQuestionKeyReply(connection: connection, requestID: requestID, target: snapshot.target)
                return
            }
            let annotations = reply["annotations"] as? [String: Any]
            var params: [String: Any] = ["sessionId": snapshot.target.sessionID, "permissionId": snapshot.target.permissionID,
                                          "optionId": option, "answers": answers]
            if let annotations { params["annotations"] = annotations }
            let intent = AgentPaneGestureIntent(gestureParams: ["intent": ["method": "_acpmux/permission_respond",
                "params": params]])
            guard let intent else {
                self.model.transport.rejectQuestionKeyReply(connection: connection, requestID: requestID,
                                                             target: snapshot.target, error: .intentInvalid)
                return
            }
            self.model.transport.offerQuestionKeyCredit(target: snapshot.target, intent: intent, context: context,
                                                        connection: connection, witness: witness) {
                await page.redeemQuestionKeySnapshot(snapshot)
            }
            guard let ticket = self.model.transport.reserveGesture(intent) else {
                // Chromium has already prevented Return and the card is waiting on
                // the host's correlated promise. Revoke this witness, release the
                // isolated snapshot, and reject that promise so the card can retry.
                self.model.transport.gestures.recordQuestionReturn(false)
                self.model.transport.rejectQuestionKeyReply(connection: connection, requestID: requestID, target: snapshot.target)
                Task { @MainActor [weak page] in
                    guard let page else { return }
                    _ = await page.redeemQuestionKeySnapshot(snapshot)
                }
                return
            }
            params["_meta"] = [AcpmuxPaneMethods.gestureTicketKey: ticket]
            let request: [String: Any] = ["jsonrpc": "2.0", "id": requestID,
                                            "method": "_acpmux/permission_respond", "params": params]
            guard let text = AcpmuxRequestIds.encode(request) else {
                self.model.transport.rejectQuestionKeyReply(connection: connection, requestID: requestID,
                                                             target: snapshot.target, error: .invalidFrame)
                return
            }
            self.model.transport.submitQuestionKeyReply(connection: connection, requestID: requestID,
                                                       target: snapshot.target, frame: text)
        }
        questionKeyBinding = bound ? binding : nil
    }
    /// The pane's side of the host transport: the native sheet it asks for (a config option that is
    /// not free) and the delivery of its frames to the page.
    func installTransport() {
        refreshQuestionKeyBinding()
        // A config option that is not free (paired devices): the user confirms it natively.
        model.onConfirmMode = { [weak self] asked, answer in
            guard let self, self.window != nil, !self.isHiddenOrHasHiddenAncestor else { return answer(false) }
            let spec = Self.confirmationSpec(asked)
            // Pane scope: a closed pane ends the sheet as Cancel, so the app-wide gate never stays shut.
            _ = CmuxDialogCenter.shared.present(spec, in: .tab(self)) { reply in answer(reply.button == "switch") }
        }
        // A folder harness profile: the user reads acpmux's prompt and enables it natively.
        model.onConfirmHarness = { [weak self] prompt, answer in
            guard let self, self.window != nil, !self.isHiddenOrHasHiddenAncestor else { return answer(false) }
            _ = CmuxDialogCenter.shared.present(Self.harnessEnableSpec(prompt), in: .tab(self)) { reply in
                answer(reply.button == "enable")
            }
        }
        installReplyLinks()
        // The host owns the acpmux socket; its frames reach the page in display-frame batches.
        let pacer = AgentPaneFramePacer(view: self)
        transportPacer = pacer
        model.transport.pacer = pacer
        model.transport.onOtherInstall = { [weak self] other in self?.showOtherInstallNotice(other) }
        model.transport.onRemoteApprovalsOff = { [weak self] approvals in self?.showRemoteApprovalsOff(approvals) }
        model.transport.onPeerApprovalsOff = { [weak self] reason in self?.showPeerApprovalsOff(reason) }
        model.transport.onQuestionStateChanged = { [weak self] in
            self?.refreshQuestionKeyBinding()
            self?.refreshOtherInstallNotice()
        }
        model.onQuestionKeySessionChange = { [weak self] in
            self?.refreshQuestionKeyBinding()
            self?.refreshOtherInstallNotice()
        }
        model.transport.deliver = { [weak self] event, done in
            guard let self else { return done() }
            if let pageEvents = self.pageEvents {
                if event.connection == self.model.transport.current {
                    pageEvents.transportDidOpen(event.connection)
                }
                // The page host's events carry no completion: the next push may follow next turn.
                if !pageEvents.publish(.transport(event)) {
                    self.model.transport.close(connection: event.connection)
                }
                // task-owner: one completion for the pacer, on the main actor
                Task { @MainActor in done() }
            } else {
                // The completion runs once the page has run the push.
                self.webView.evaluateJavaScript(event.script) { _, _ in done() }
            }
        }
    }

    /// The native sheet for `asked`: the option and the value it would take.
    static func confirmationSpec(_ asked: AgentPaneModeConfirmation) -> CmuxDialogSpec {
        let line = switch asked {
        case .option(let id, let value): confirmationOptionMessage(id: id, value: value)
        // A mode never reaches the sheet (`needsSheet`); named like an option if it did.
        case .mode(let mode): String(format: confirmOptionMessage, "mode", mode)
        }
        return CmuxDialogSpec(title: confirmModeTitle, lines: [line],
                              buttons: [.cancel(), CmuxDialogButton(id: "switch", title: confirmModeButton, role: .destructive)])
    }

    /// Formats protocol values for a native confirmation while retaining raw identifiers for logs.
    private static func confirmationOptionMessage(id: String, value: String) -> String {
        let name = switch id {
        case "fast", "fast-mode": confirmFastModeName
        default: id
        }
        let displayValue = switch value.lowercased() {
        case "true", "on": confirmOptionOn
        case "false", "off": confirmOptionOff
        default: value
        }
        return String(format: confirmOptionMessage, name, displayValue)
    }

    /// The gesture monitor's handler, on the main thread before AppKit dispatches `event`: the
    /// decision reads event-time state, once, and is never made again later.
    func monitored(_ event: NSEvent) { judge(event, eventWindow: event.window) }

    /// A key press with the page focused, or a click on the page, by the person (``AgentPanePersonInput``):
    /// the user's gesture. `eventWindow` is the event's window (tests pass it: a synthesized event cannot resolve it).
    public func judge(_ event: NSEvent, eventWindow: NSWindow?) {
        // A Chromium page has its own window, a child of the pane's.
        if let window, let eventWindow, eventWindow !== window, eventWindow.parent === window {
            return judgeChromium(event, eventWindow: eventWindow)
        }
        guard let window, eventWindow === window else { return }
        switch event.type {
        case .keyDown:
            guard !event.isARepeat, (window.firstResponder as? NSView)?.isDescendant(of: webView) == true else { return }
        default:
            guard webView.bounds.contains(webView.convert(event.locationInWindow, from: nil)) else { return }
        }
        // Repeats belong to the original press, whose DOM proof may still be redeeming.
        // A new page event revokes it, even when posted input cannot grant a fresh witness.
        model.transport.gestures.recordQuestionReturn(false)
        guard AgentPanePersonInput.isPerson(event, sources: eventSources) else { return }
        model.transport.gestures.record(click: event.type != .keyDown)
        if event.type == .keyDown { model.transport.gestures.recordQuestionReturn(Self.isReturnKey(event)) }
    }

    /// The same for an event in the Chromium page's own window (a child of the pane's window): a key
    /// while the page has the keyboard, or a click on the page.
    private func judgeChromium(_ event: NSEvent, eventWindow: NSWindow?) {
        guard page?.showsChromium == true, let eventWindow else { return }
        switch event.type {
        case .keyDown:
            // CEF can leave its child window non-key while a native file picker or attachment
            // handoff finishes. The event is still the person's physical key (checked below),
            // and the child is still this pane's page, so do not turn that brief focus transition
            // into a rejected send.
            guard !event.isARepeat,
                  chromiumPageContains(CGPoint(x: eventWindow.frame.midX, y: eventWindow.frame.midY), eventWindow: eventWindow) else { return }
        default:
            guard chromiumPageContains(eventWindow.convertPoint(toScreen: event.locationInWindow), eventWindow: eventWindow) else { return }
        }
        model.transport.gestures.recordQuestionReturn(false)
        guard AgentPanePersonInput.isPerson(event, sources: eventSources) else { return }
        model.transport.gestures.record(click: event.type != .keyDown)
        if event.type == .keyDown { model.transport.gestures.recordQuestionReturn(Self.isReturnKey(event)) }
    }

    /// Return on the main keyboard is key code 36; the numeric keypad's Enter is 76.
    private static func isReturnKey(_ event: NSEvent) -> Bool {
        event.keyCode == 36 || event.keyCode == 76
    }
}
