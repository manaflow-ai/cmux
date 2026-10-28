import AppKit
import CmuxNextFocus

/// A surface's primary input (R65, spec app-screens.md section 3): Home's
/// message box, the agent pane's composer, an app screen's
/// `presentation.primaryInput`. It is the one answer to "where does the
/// keyboard go in this surface", for both ways a key can get there:
///
/// - the surface's pane gets focus (a pane-focus shortcut, Cmd-1…9, the
///   sidebar, a click, app or window activation, a closed popover):
///   `FocusEffectApplier` gives ``primaryInputView`` the keyboard unless
///   ``primaryInputShouldTakeKeyboard(from:)`` says the responder keeps it;
/// - a printable key arrives while the surface has the keyboard and none of
///   its text inputs does: the key dispatcher sends it here
///   (``beginTyping(with:)``), so typing starts in the primary input and the
///   first key is not lost. Command and Control chords resolve first.
///
/// A surface opts in by conforming its content view (`TabContent.view`, or
/// an internal page's `InternalPageView.content`). A view that wraps the
/// surface (Home's dock page, a Home tab) conforms by forwarding, so every
/// container of the same surface lands the keyboard in the same place.
@MainActor
protocol PrimaryInputTarget: AnyObject {
    /// The primary input itself (Home: the message box's text view); nil
    /// when the surface shows none now (Home's Channels page, a Home with no
    /// conversation shown yet).
    var primaryInputView: NSView? { get }
    /// Whether the surface getting the keyboard moves it from `responder`
    /// (the window's first responder now) to ``primaryInputView``: yes from
    /// anywhere outside the surface; inside it, no only for a place the
    /// person chose to type or navigate in (a visible editable text field, a
    /// list moved with the arrow keys, a text selection to copy).
    func primaryInputShouldTakeKeyboard(from responder: NSResponder?) -> Bool
    /// A printable key may go to the primary input now: none of the
    /// surface's text inputs has the keyboard. Default: the window's first
    /// responder is not a visible, editable text input (``NSResponder/ownsTypedText``).
    var acceptsRedirectedTyping: Bool { get }
    /// Whether `event` (a key-down no shortcut took, not a Command or
    /// Control chord) belongs to the primary input wherever in the surface
    /// the keyboard is. The key dispatcher's one path for keys bound to a
    /// surface's primary input (`KeyRouter.typesIntoPrimaryInput`): a
    /// surface adds keys here (Home's message history on Up and Down)
    /// instead of routing them itself. Default: printable keys and dead keys.
    func routesToPrimaryInput(_ event: NSEvent) -> Bool
    /// Focuses the primary input and types `event` into it. Default: the
    /// input becomes first responder, then gets the key-down itself, so an
    /// input method or a dead key composes there.
    func beginTyping(with event: NSEvent)
}

extension PrimaryInputTarget {
    var acceptsRedirectedTyping: Bool {
        guard let input = primaryInputView, let window = input.window, input.isShownForInput else { return false }
        return !(window.firstResponder?.ownsTypedText ?? false)
    }

    func routesToPrimaryInput(_ event: NSEvent) -> Bool {
        KeyRouter.isPrintable(event) || KeyRouter.isDeadKey(event)
    }

    func beginTyping(with event: NSEvent) {
        guard let input = primaryInputView, let window = input.window else { return }
        if window.firstResponder !== input { guard window.makeFirstResponder(input) else { return } }
        input.keyDown(with: event)
    }

    /// The surface got the keyboard (`FocusEffectApplier`): its primary
    /// input takes it unless the responder keeps it, or a pending creation
    /// owns the window's keyboard (a new terminal asked for while Home showed:
    /// `NSWindow.pendingCreationOwnsKeyboard`). Returns false when the
    /// surface shows no primary input in `window` now (the caller then
    /// focuses its own target).
    @discardableResult
    func landKeyboard(in window: NSWindow) -> Bool {
        guard let input = primaryInputView, input.window === window, input.isShownForInput else { return false }
        if window.firstResponder !== input, !window.pendingCreationOwnsKeyboard, primaryInputShouldTakeKeyboard(from: window.firstResponder) {
            window.makeFirstResponder(input)
        }
        return true
    }
}

extension TabContent {
    /// The content's primary input, when its view (an internal page's
    /// provider view) declares one.
    @MainActor var primaryInput: (any PrimaryInputTarget)? {
        if case .page(let page) = self { return page.content as? any PrimaryInputTarget }
        return view as? any PrimaryInputTarget
    }

    /// The focus applier's step when this content's pane gets the keyboard
    /// (`FocusEffectApplier`, `.page` and `.conversation`): its primary input
    /// takes it by the surface's rule. False when the content shows no
    /// primary input in `window` now: the caller focuses `focusTarget`.
    @MainActor func landKeyboardInPrimaryInput(in window: NSWindow) -> Bool {
        primaryInput?.landKeyboard(in: window) ?? false
    }
}

extension NSWindow {
    /// Whether a primary input inside `view` may take this window's keyboard when nobody asked for it
    /// (a surface that shows content by itself: Home's default conversation, its message box installed).
    /// Nothing in the window holds the keyboard (the window itself or nil is first responder) and, when
    /// `view` is in a pane of a cmux window, its focus model keeps the keyboard in that pane's content.
    /// The first responder alone cannot say it: a Chromium page that has the keys leaves the cmux window
    /// itself first responder, and Home took them from a restored browser page (QA chrome-parity-v2-2-2
    /// bug 1). Outside every pane (classic Home as a top page), or in a pane the focus model does not
    /// know yet (its first topology still to come), the first responder rule alone decides.
    /// - Parameter view: The surface's view, in this window.
    /// - Returns: True when the surface may give its primary input the keyboard now.
    @MainActor func keyboardIsFree(for view: NSView) -> Bool {
        guard firstResponder === self || firstResponder == nil, !pendingCreationOwnsKeyboard else { return false }
        guard let controller = windowController as? WindowController,
              case .content(let pane) = FocusResponderClassifier.classify(view, in: controller) else { return true }
        let focus = controller.focus.currentState()
        guard focus.topology.panes.contains(where: { $0.id == pane }) else { return true }
        return focus.keepsKeyboard(inContentOf: pane)
    }
}

extension NSWindow {
    /// Whether a creation asked for in this cmux window with focus (a new terminal, pane or tab; a new workspace's
    /// terminal) holds its keys and the person has not moved on since (no user intent after it): the keyboard is that
    /// creation's, so no primary input takes it by itself, on a pane focus nobody chose, a shown conversation or an
    /// installed message box (Chrome's rule: a tab that is not the one asked for never takes focus by itself). Keys typed
    /// meanwhile wait for the creation (`CreationInputCoordinator`). False outside a cmux window.
    @MainActor var pendingCreationOwnsKeyboard: Bool {
        guard let controller = windowController as? WindowController else { return false }
        return controller.services.keyRouter.creationInputCoordinator.claimsKeyboard(in: self, generation: controller.focus.state.generation)
    }
}

extension KeyRouter {
    /// A key that types text: no Command or Control, and a character that
    /// is neither a control character nor a function key (arrows, Return,
    /// Tab, Escape, Delete stay the surface's).
    nonisolated static func isPrintable(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, !isChord(event.modifierFlags),
              let scalar = event.characters?.unicodeScalars.first else { return false }
        return isTypedScalar(scalar)
    }

    /// A dead key (Option-E, Option-U, the `´` key of a European layout): it
    /// types nothing yet (`characters` is empty) and the next key composes
    /// with it, so it must reach the same input as that next key.
    nonisolated static func isDeadKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, !isChord(event.modifierFlags), event.characters?.isEmpty == true,
              let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else { return false }
        return isTypedScalar(scalar)
    }

    /// Neither a control character nor a function key (arrows, Delete).
    nonisolated private static func isTypedScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x20 && scalar.value != 0x7F && !(0xF700...0xF8FF).contains(scalar.value)
    }

    /// Surfaces that may declare a primary input.
    nonisolated static func mayHavePrimaryInput(_ resolved: FocusState.Resolved) -> Bool {
        switch resolved {
        case .conversation, .agentPage, .page: true
        default: false
        }
    }
}
