public import AppKit
import CmuxNextDesign
import CmuxNextWakeups

extension AgentPaneView {
    /// The pane's side of the host transport: the native sheet it asks for (a config option that is
    /// not free) and the delivery of its frames to the page.
    func installTransport() {
        // A config option that is not free (paired devices): the user confirms it natively.
        model.onConfirmMode = { [weak self] asked, answer in
            // visibility-walk-allow: a sheet AppKit shows over this pane: one that AppKit does not show refuses at once, as the sheet could not be seen; read once per ask
            guard let self, self.window != nil, !self.isHiddenOrHasHiddenAncestor else { return answer(false) }
            let spec = Self.confirmationSpec(asked)
            // Pane scope: a closed pane ends the sheet as Cancel, so the app-wide gate never stays shut.
            _ = CmuxDialogCenter.shared.present(spec, in: .tab(self)) { reply in answer(reply.button == "switch") }
        }
        // A folder harness profile: the user reads acpmux's prompt and enables it natively.
        model.onConfirmHarness = { [weak self] prompt, answer in
            // visibility-walk-allow: as above, the sheet AppKit shows over this pane; read once per ask
            guard let self, self.window != nil, !self.isHiddenOrHasHiddenAncestor else { return answer(false) }
            _ = CmuxDialogCenter.shared.present(Self.harnessEnableSpec(prompt), in: .tab(self)) { reply in
                answer(reply.button == "enable")
            }
        }
        installReplyLinks()
        // The host owns the acpmux socket; its frames reach the page in display-frame batches.
        let pacer = AgentPaneFramePacer(view: self, mainThread: mainThread)
        let completions = model.deadlines.work.board.owner("agentPane.transport.delivered")
        transportPacer = pacer
        model.transport.pacer = pacer
        model.transport.onOtherInstall = { [weak self] other in self?.showOtherInstallNotice(other) }
        model.transport.onRemoteApprovalsOff = { [weak self] approvals in self?.showRemoteApprovalsOff(approvals) }
        model.transport.onPeerApprovalsOff = { [weak self] reason in self?.showPeerApprovalsOff(reason) }
        model.transport.deliver = { [weak self, completions] event, done in
            guard let self else { return done() }
            self.pageEvents.transportDidOpen(event.connection)
            // The page host's events carry no completion: the next push may follow next turn.
            if !self.pageEvents.publish(.transport(event)) {
                self.model.transport.close(connection: event.connection)
            }
            // The page host's push is queued, not run: the pacer hears it done in a later visible task, so its next
            // flush never runs in this one (Chrome's renderer acks a frame's IPC on a later task).
            self.model.deadlines.work.post(.visible, owner: completions) { done() }
        }
    }

    /// The page lifecycle froze the chat's page (``AgentPageLifecycleTarget/freeze()``): the transport
    /// makes no call and arms no deadline until the thaw.
    func pageDidFreeze() {
        transportPacer?.pageDidFreeze()
    }

    /// The chat's page runs again, in the thaw's turn (``AgentPageLifecycleTarget/thaw()``): what the
    /// transport kept goes in one call, before the page shows and the router sends its held batch. When
    /// the freeze closed the connection (``closeTransportWhileFrozen()``), that call ends with the close
    /// and the page opens again on the same client, resuming after its last event.
    func pageDidThaw() {
        model.transport.pageDidThaw()
        transportPacer?.pageDidThaw()
    }

    /// The page's owner found nothing on the frozen chat's connection waiting for it (no turn runs or
    /// waits on the person): the connection closes until the thaw, if the page is still
    /// frozen (``AgentPaneTransport/closeWhileFrozen()``).
    package func closeTransportWhileFrozen() {
        model.transport.closeWhileFrozen()
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

    /// A key press with the page focused, or a click on the page, by the person (``AgentPanePersonInput``):
    /// the user's gesture. ``AgentPaneGestureRouter`` calls it before AppKit dispatches `event`, so the
    /// decision reads event-time state, once. `eventWindow` is the event's window (tests pass it: a
    /// synthesized event cannot resolve it).
    public func judge(_ event: NSEvent, eventWindow: NSWindow?) {
        // A Chromium page has its own window, a child of the pane's.
        if let window, let eventWindow, eventWindow !== window, eventWindow.parent === window {
            return judgeChromium(event, eventWindow: eventWindow)
        }
        guard let window, eventWindow === window, AgentPanePersonInput.isPerson(event) else { return }
        // The page view holds whichever engine's view shows the chat, at the same frame.
        switch event.type {
        case .keyDown:
            guard !event.isARepeat, (window.firstResponder as? NSView)?.isDescendant(of: page) == true else { return }
        default:
            guard page.bounds.contains(page.convert(event.locationInWindow, from: nil)) else { return }
        }
        model.transport.gestures.record(click: event.type != .keyDown)
    }

    /// The same for an event in the Chromium page's own window (a child of the pane's window): a key
    /// while the page has the keyboard, or a click on the page.
    private func judgeChromium(_ event: NSEvent, eventWindow: NSWindow?) {
        guard page.showsChromium, let eventWindow, AgentPanePersonInput.isPerson(event) else { return }
        switch event.type {
        case .keyDown:
            // CEF can leave its child window non-key while a native file picker or attachment
            // handoff finishes. The event is still the person's physical key (checked above),
            // and the child is still this pane's page, so do not turn that brief focus transition
            // into a rejected send.
            guard !event.isARepeat,
                  chromiumPageContains(CGPoint(x: eventWindow.frame.midX, y: eventWindow.frame.midY), eventWindow: eventWindow) else { return }
        default:
            guard chromiumPageContains(eventWindow.convertPoint(toScreen: event.locationInWindow), eventWindow: eventWindow) else { return }
        }
        model.transport.gestures.record(click: event.type != .keyDown)
    }
}
