import AppKit
import CmuxNextActions
import CmuxNextPages
import CmuxNextTerminal
import CmuxNextFocus

// Typing into a screen before it can take keys (spec app-screens.md section
// 3, R59): the primary input of a screen that has one (R65), and the
// type-ahead queue of a page whose document has not focused its primary
// input yet (`PageInputReadiness`). Shortcuts resolve before either.
extension KeyRouter {
    /// A key on a screen whose primary input claims it (R65; Home's message
    /// box: printable and dead keys, `PrimaryInputTarget.routesToPrimaryInput`)
    /// while none of the screen's text inputs has the keyboard: focus that
    /// input and give it the key. This is the one path for keys bound to a
    /// screen's primary input from anywhere in the screen. Typing in a
    /// terminal never looks up the window (typing-latency path).
    func typesIntoPrimaryInput(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard let window, !(window.firstResponder is TerminalSurfaceView), event.type == .keyDown,
              !Self.isChord(event.modifierFlags) else { return false }
        guard let focused = focusedPrimaryInput(in: window), focused.input.routesToPrimaryInput(event) else { return false }
        let (focus, target) = (focused.focus, focused.input)
        let facts = Facts(hasMarkedText: (window.firstResponder as? any NSTextInputClient)?.hasMarkedText() == true,
                          primaryInputReady: target.acceptsRedirectedTyping, primaryInputClaimsKey: true)
        guard decide(event, focus: focus, keyWindow: .content, facts: facts) == .primaryInput else { return false }
        decided.add(event)
        target.beginTyping(with: event)
        return true
    }

    /// The focused pane's primary input in `window`, a main window, with the
    /// focus it was resolved from; nil when the pane shows none.
    func focusedPrimaryInput(in window: NSWindow?) -> (focus: FocusState, input: any PrimaryInputTarget)? {
        let (controller, kind) = focus(for: window)
        guard let controller, kind == .content else { return nil }
        let focus = controller.focus.state
        guard Self.mayHavePrimaryInput(focus.resolved), let pane = focus.resolved.pane,
              let target = controller.content?.paneController(key: pane)?.currentContent?.primaryInput else { return nil }
        return (focus: focus, input: target)
    }

    /// The target of a nil-targeted paste command in `window` instead of
    /// AppKit's `found` (``PrimaryInputPasteRoute``); nil keeps `found`.
    func pasteTarget(for action: Selector, found: AnyObject?, in window: NSWindow?) -> AnyObject? {
        guard PrimaryInputPasteRoute.actions.contains(action), let focused = focusedPrimaryInput(in: window) else { return nil }
        return PrimaryInputPasteRoute().target(for: action, found: found, in: window, input: focused.input)
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
                // A Delete while the taken text is being inserted, with nothing queued after it, is
                // for that text: it goes to the page once the text landed (it was dropped before).
                typeAhead.deleteBackward(surface: surface, delivering: deliveringTypeAhead == surface)
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
    /// one is delivered follow it. Deletes typed while it was on its way go
    /// right after it, before any text queued later.
    func flushTypeAhead(_ surface: String, into readiness: PageInputReadiness) {
        guard deliveringTypeAhead == nil, let text = typeAhead.take(surface: surface, now: .now) else { return }
        deliveringTypeAhead = surface
        let expectedEpoch = readiness.focusEpoch
        // task-owner: one queued insertion into the page, then its Deletes; the next flush runs after it
        Task { [weak self, weak readiness] in
            guard let self, let readiness else { return }
            guard await readiness.insert(text, expectedEpoch: expectedEpoch) else {
                // The original element disappeared or refused the insert; discard Deletes tied
                // to that failed text so they cannot hit a later focused field.
                self.typeAhead.takeDeletes()
                self.deliveringTypeAhead = nil
                return
            }
            // Ends when no Delete came in during the last edit; each pass sends what came before it.
            while self.typeAhead.pendingDeletes > 0 {
                // Consume this batch before awaiting the page so Deletes arriving during the
                // asynchronous edit remain queued for the next pass.
                let deletes = self.typeAhead.takeDeletes()
                let applied = await readiness.deleteBackward(deletes, expectedEpoch: expectedEpoch)
                if !applied {
                    self.typeAhead.takeDeletes()
                    break
                }
            }
            deliveringTypeAhead = nil
            flushTypeAhead(surface, into: readiness)
        }
    }

    /// A chord or another key ends the queue.
    func dropTypeAhead() {
        if deliveringTypeAhead == nil {
            typeAhead.drop()
        } else {
            // The taken text is still on its way to the page. Keep Deletes typed after it so a
            // chord/Return cannot clear edits that must follow that text.
            typeAhead.dropPendingText()
        }
        typeAheadFocus = nil
    }

    /// Focus moved off the page the keys wait for: they are dropped.
    func typeAheadFocusDidSettle(_ resolved: FocusState.Resolved) {
        guard let waiting = typeAheadFocus, waiting != resolved else { return }
        dropTypeAhead()
    }
}
