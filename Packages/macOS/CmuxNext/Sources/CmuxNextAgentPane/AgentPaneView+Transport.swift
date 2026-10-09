import AppKit
import CmuxNextDesign
import WebKit

extension AgentPaneView {
    /// The pane's side of the host transport: the native sheet it asks for (a config option that is
    /// not free) and the delivery of its frames to the page.
    func installTransport() {
        // A config option that is not free (paired devices): the user confirms it natively.
        model.onConfirmMode = { [weak self] asked, answer in
            guard let self, self.window != nil else { return answer(false) }
            let spec = Self.confirmationSpec(asked)
            // Pane scope: a closed pane ends the sheet as Cancel, so the app-wide gate never stays shut.
            _ = CmuxDialogCenter.shared.present(spec, in: .tab(self)) { reply in answer(reply.button == "switch") }
        }
        // A folder harness profile: the user reads acpmux's prompt and enables it natively.
        model.onConfirmHarness = { [weak self] prompt, answer in
            guard let self, self.window != nil else { return answer(false) }
            _ = CmuxDialogCenter.shared.present(Self.harnessEnableSpec(prompt), in: .tab(self)) { reply in
                answer(reply.button == "enable")
            }
        }
        installReplyLinks()
        // The host owns the acpmux socket; its frames reach the page in display-frame batches.
        let pacer = AgentPaneFramePacer(view: self)
        transportPacer = pacer
        model.transport.pacer = pacer
        model.transport.deliver = { [weak self] event, done in
            guard let self else { return done() }
            if let pageEvents = self.pageEvents {
                // The page host's events carry no completion: the next push may follow next turn.
                pageEvents.publish(.transport(event))
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
        case .option(let id, let value): String(format: confirmOptionMessage, id, value)
        // A mode never reaches the sheet (`needsSheet`); named like an option if it did.
        case .mode(let mode): String(format: confirmOptionMessage, "mode", mode)
        }
        return CmuxDialogSpec(title: confirmModeTitle, lines: [line],
                              buttons: [.cancel(), CmuxDialogButton(id: "switch", title: confirmModeButton, role: .destructive)])
    }

    /// The gesture monitor's handler, on the main thread before AppKit dispatches `event`: the
    /// decision reads event-time state, once, and is never made again later.
    func monitored(_ event: NSEvent) { judge(event, eventWindow: event.window) }

    /// A key press with the page focused, or a click on the page: the user's gesture. `eventWindow`
    /// is the event's window (tests pass it: a synthesized event cannot resolve it).
    func judge(_ event: NSEvent, eventWindow: NSWindow?) {
        guard let window, eventWindow === window else { return }
        switch event.type {
        case .keyDown:
            guard !event.isARepeat, (window.firstResponder as? NSView)?.isDescendant(of: webView) == true else { return }
        default:
            guard webView.bounds.contains(webView.convert(event.locationInWindow, from: nil)) else { return }
        }
        model.transport.gestures.record()
    }
}
