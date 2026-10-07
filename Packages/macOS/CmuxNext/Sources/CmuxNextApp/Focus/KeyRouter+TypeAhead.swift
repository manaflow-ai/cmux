import AppKit
import CmuxNextActions
import CmuxNextPages
import CmuxNextTerminal

// Typing into a screen before it can take keys (spec app-screens.md section
// 3, R59): the primary input of a screen that has one (R65), and the
// type-ahead queue of a page whose document has not focused its primary
// input yet (`PageInputReadiness`). Shortcuts resolve before either.
extension KeyRouter {
    /// Starts the action-owned buffer before a cold New Tab view exists.
    func beginNewTabInput(for pane: String) {
        newTabInput[pane] = NewTabInputBuffer()
    }

    /// Abandons an action-owned buffer when opening the page was refused.
    func cancelNewTabInput(for pane: String) {
        newTabInput[pane] = nil
    }

    /// Captures a printable key while Cmd-T is presenting its page. This runs
    /// before the old responder can see the key, so a cold page cannot lose it.
    func captureNewTabInput(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard let window, Self.isPrintable(event) else { return false }
        let (controller, kind) = focus(for: window)
        guard kind == .content, let controller,
              let pane = controller.focus.state.resolved.pane, var buffer = newTabInput[pane] else { return false }
        buffer.append(event.characters ?? "")
        newTabInput[pane] = buffer
        return true
    }

    /// Moves the action-owned text into the existing readiness queue once the
    /// selected tab is the New Tab page. The readiness callback replays it in order.
    func promoteNewTabInput(_ resolved: FocusState.Resolved, in window: NSWindow?) {
        guard case .agentPage(let pane, let tab) = resolved, newTabInput[pane] != nil,
              let window else { return }
        let (controller, kind) = focus(for: window)
        guard kind == .content, let controller,
              let paneController = controller.content?.paneController(key: pane),
              paneController.currentTabKey == tab, services?.agentTabs.isNewTabPage(tab) == true,
              let readiness = paneController.currentContent?.inputReadiness,
              var buffer = newTabInput.removeValue(forKey: pane), let text = buffer.take() else { return }
        let surface = String(describing: ObjectIdentifier(readiness))
        typeAhead.append(text, surface: surface, now: .now)
        typeAheadFocus = resolved
        readiness.onReady = { [weak self, weak readiness] in
            guard let self, let readiness else { return }
            self.flushTypeAhead(surface, into: readiness)
        }
        if readiness.isReady { flushTypeAhead(surface, into: readiness) }
    }

    /// A printable key on a screen whose primary input should take it
    /// (R65): focus that input and type the key there. Typing in a terminal
    /// never looks up the window (typing-latency path).
    func typesIntoPrimaryInput(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard let window, !(window.firstResponder is TerminalSurfaceView), Self.isPrintable(event) else { return false }
        let (controller, kind) = focus(for: window)
        guard let controller, kind == .content else { return false }
        let focus = controller.focus.state
        guard Self.mayHavePrimaryInput(focus.resolved), let pane = focus.resolved.pane,
              let target = controller.content?.paneController(key: pane)?.currentContent?.primaryInput else { return false }
        let facts = Facts(hasMarkedText: (window.firstResponder as? any NSTextInputClient)?.hasMarkedText() == true,
                          primaryInputReady: target.acceptsRedirectedTyping)
        guard decide(event, focus: focus, keyWindow: kind, facts: facts) == .primaryInput else { return false }
        decided.add(event)
        target.beginTyping(with: event)
        return true
    }

    /// Pages whose keys may wait for their document: agent pages (the new
    /// tab page, chats) and React pages (CmuxNextPages).
    nonisolated static func mayQueueTyping(_ resolved: FocusState.Resolved) -> Bool {
        switch resolved {
        case .agentPage, .page: true
        default: false
        }
    }

    /// A printable key on a page that cannot take typing yet: queue it for
    /// that page, in order; it goes to the page's focused primary input
    /// when the page reports it ready. Delete edits the queue; another key
    /// that is not typing ends the queue, so no key arrives out of order.
    func typesAhead(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard let window, !(window.firstResponder is TerminalSurfaceView) else { return false }
        let (controller, kind) = focus(for: window)
        guard let controller, kind == .content else { return false }
        let focus = controller.focus.state
        guard Self.mayQueueTyping(focus.resolved), let pane = focus.resolved.pane,
              let readiness = controller.content?.paneController(key: pane)?.currentContent?.inputReadiness else { return false }
        let surface = String(describing: ObjectIdentifier(readiness))
        let waiting = typeAhead.pending(for: surface) || deliveringTypeAhead == surface
        let facts = Facts(pageInputPending: !readiness.isReady || waiting)
        guard decide(event, focus: focus, keyWindow: kind, facts: facts) == .typeAhead else {
            guard waiting else { return false }
            if event.keyCode == Self.deleteKeyCode {
                typeAhead.deleteBackward(surface: surface)
                decided.add(event)
                return true
            }
            dropTypeAhead()
            return false
        }
        decided.add(event)
        typeAhead.append(event.characters ?? "", surface: surface, now: .now)
        typeAheadFocus = focus.resolved
        readiness.onReady = { [weak self, weak readiness] in
            guard let self, let readiness else { return }
            flushTypeAhead(surface, into: readiness)
        }
        if readiness.isReady { flushTypeAhead(surface, into: readiness) }
        return true
    }

    nonisolated static let deleteKeyCode: UInt16 = 51

    /// Delivers the queued text, one insertion at a time; keys typed while
    /// one is delivered follow it.
    func flushTypeAhead(_ surface: String, into readiness: PageInputReadiness) {
        guard deliveringTypeAhead == nil, let text = typeAhead.take(surface: surface, now: .now) else { return }
        deliveringTypeAhead = surface
        // task-owner: one queued insertion into the page; the next flush runs after it
        Task { [weak self, weak readiness] in
            guard let readiness else { return }
            _ = await readiness.insert(text)
            guard let self else { return }
            deliveringTypeAhead = nil
            flushTypeAhead(surface, into: readiness)
        }
    }

    /// A chord or another key ends the queue.
    func dropTypeAhead() {
        typeAhead.drop()
        typeAheadFocus = nil
    }

    /// Focus moved off the page the keys wait for: they are dropped.
    func typeAheadFocusDidSettle(_ resolved: FocusState.Resolved) {
        guard let waiting = typeAheadFocus, waiting != resolved else { return }
        dropTypeAhead()
    }
}
