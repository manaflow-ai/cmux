import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextFocusUI
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
        let otherPage = focus(for: window).0.map { keyInOtherPage(window, controller: $0) } ?? false
        let (focus, target) = (focused.focus, focused.input)
        let facts = Facts(hasMarkedText: (window.firstResponder as? any NSTextInputClient)?.hasMarkedText() == true,
                          primaryInputReady: target.acceptsRedirectedTyping, primaryInputClaimsKey: true, keyInOtherPage: otherPage)
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
    /// AppKit's `found` (``PrimaryInputPasteRoute``, then
    /// ``ChromiumPasteAndMatchStyleRoute``); nil keeps `found`.
    func pasteTarget(for action: Selector, found: AnyObject?, in window: NSWindow?) -> AnyObject? {
        guard PrimaryInputPasteRoute.actions.contains(action) else { return nil }
        if let focused = focusedPrimaryInput(in: window),
           let primary = PrimaryInputPasteRoute().target(for: action, found: found, in: window, input: focused.input) { return primary }
        return ChromiumPasteAndMatchStyleRoute().target(for: action, found: found, in: window)
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
        guard focus.resolved.mayQueueTyping, let pane = focus.resolved.pane, let readiness = controller.content?.paneController(key: pane)?.currentContent?.inputReadiness else { return false }
        let surface = String(describing: ObjectIdentifier(readiness))
        let waiting = typeAhead.pending(for: surface) || deliveringTypeAhead == surface || typeAheadTail.holds(surface)
        let otherPage = keyInOtherPage(window, controller: controller)
        let facts = Facts(pageInputPending: !readiness.isReady || waiting, keyInOtherPage: otherPage)
        // Return follows the text typed before it, and the keys after it follow Return: they run once that text landed.
        if !otherPage, typeAheadTail.takes(keyCode: event.keyCode, chord: Self.isChord(event.modifierFlags), surface: surface, behindText: waiting) {
            decided.add(event)
            typeAheadTail.hold(HeldTypeAheadKey(event: event, window: window), surface: surface, delivering: deliveringTypeAhead == surface)
            if typeAheadFocus == nil { typeAheadFocus = TypeAheadWait(focus: focus.resolved, page: surface) }
            readiness.whenReady { [weak self, weak readiness] in readiness.map { self?.flushTypeAhead(surface, into: $0) } }
            return true
        }
        guard decide(event, focus: focus, keyWindow: kind, facts: facts) == .typeAhead else {
            // A key in another page's window edits nothing queued for this one.
            guard waiting, !otherPage else { return false }
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
        typeAheadFocus = TypeAheadWait(focus: focus.resolved, page: surface)
        readiness.whenReady { [weak self, weak readiness] in readiness.map { self?.flushTypeAhead(surface, into: $0) } }
        return true
    }

    nonisolated static let deleteKeyCode: UInt16 = 51

    /// Whether `window`, the key window, is the Chromium page window of a page shown in another pane
    /// than the focused one (``KeyFacts/keyInOtherPage``): the focus model named a Markdown page
    /// opened beside a chat while the chat's page window kept the keys (#25666). Only a pane's page
    /// at its place counts: the hidden New Tab spare, DevTools and the focused page's own window
    /// before it is placed are not another page, and keep their type-ahead.
    func keyInOtherPage(_ window: NSWindow, controller: WindowController) -> Bool {
        guard window !== controller.window, window.isChromiumPageWindow, let content = controller.content else { return false }
        let focused = controller.focus.state.resolved.pane
        return content.panes.values.contains { pane in
            pane.paneKey != focused && (pane.currentContent?.childWindowTab as? CEFTab)?.isPageWindow(window) == true
        }
    }

    /// Delivers the queued text, one insertion at a time; keys typed while
    /// one is delivered follow it. Deletes typed while it was on its way go
    /// right after it, before any text queued later.
    func flushTypeAhead(_ surface: String, into readiness: PageInputReadiness) {
        guard deliveringTypeAhead == nil else { return }
        // Nothing more is on its way: the keys held behind the text run now, as typed (out of the tail first, so none is held again).
        guard let text = typeAhead.take(surface: surface, now: .now) else { return typeAheadTail.settle(surface: surface).forEach { key in if let window = key.window { heldKeyReplay(key.event, window, self) } } }
        typeAheadTail.textWasTaken(surface: surface)
        deliveringTypeAhead = surface
        let expectedEpoch = readiness.focusEpoch
        // task-owner: one queued insertion into the page, then its Deletes; the next flush runs after it
        Task { [weak self, weak readiness] in
            guard let self, let readiness else { return }
            guard await readiness.insert(text, expectedEpoch: expectedEpoch) else {
                // The original element disappeared or refused the insert; discard Deletes tied
                // to that failed text so they cannot hit a later focused field.
                self.typeAhead.takeDeletes()
                self.typeAheadTail.drop() // a Return alone would act on a field its text never reached
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
        typeAheadTail.drop()
        typeAheadFocus = nil
    }

    /// Focus moved off the page the keys wait for: they are dropped. The page under its store id is the same page.
    func typeAheadFocusDidSettle(_ resolved: FocusState.Resolved, in window: NSWindow?) {
        let page = resolved.pane.flatMap { pane in window.flatMap { focus(for: $0).0?.content?.paneController(key: pane)?.currentContent?.inputReadiness } }
        guard let waiting = typeAheadFocus, !waiting.survives(resolved, page: page.map { String(describing: ObjectIdentifier($0)) }) else { return }
        dropTypeAhead()
    }
}
