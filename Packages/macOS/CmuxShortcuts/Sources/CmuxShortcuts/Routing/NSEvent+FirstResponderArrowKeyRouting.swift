public import AppKit

/// First-responder arrow and Ctrl-N/Ctrl-P key-down dispatch decisions for the
/// app's shortcut routing, expressed as operations on the event modifier state
/// that drives them.
///
/// The cmux app target used to inline these as free functions in its shortcut
/// routing support file (`shouldDispatchTerminalArrowViaFirstResponderKeyDown`,
/// `shouldDispatchTextBoxInputArrowViaFirstResponderKeyDown`, and siblings).
/// They are pure decisions over a modifier-flag set plus the pressed key and a
/// few first-responder predicates, with no AppKit responder, `Workspace`, or
/// `AppDelegate` reach, so they belong in this package next to the shortcut
/// event decode and chord routing that share its keystroke hot path.
///
/// They are modeled as an extension on ``AppKit/NSEvent/ModifierFlags`` (the
/// type they operate on) rather than a static-method utility, so call sites read
/// `flags.shouldDispatch…` and no caseless namespace is introduced. The bodies
/// are byte-faithful lifts; the internal normalization mirrors the app target's
/// `browserOmnibarNormalizedModifierFlags`, which stays in the app target for
/// its non-routing callers.
extension NSEvent.ModifierFlags {
    /// The modifier flags reduced to the device-independent set used for the
    /// first-responder key-routing decisions, dropping the numeric-pad,
    /// function, and caps-lock bits.
    var firstResponderKeyRoutingNormalized: NSEvent.ModifierFlags {
        intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
    }

    /// Returns true when a terminal arrow key-equivalent should be sent through keyDown.
    public func shouldDispatchTerminalArrowViaFirstResponderKeyDown(
        keyCode: UInt16,
        firstResponderIsTerminal: Bool,
        firstResponderHasMarkedText: Bool = false
    ) -> Bool {
        guard firstResponderIsTerminal, !firstResponderHasMarkedText, (123...126).contains(keyCode) else { return false }
        return !firstResponderKeyRoutingNormalized.contains(.command)
    }

    /// Whether a horizontal arrow keyDown belongs to a focused command-palette
    /// field editor so it should be forwarded to `firstResponder.keyDown`.
    public func shouldDispatchCommandPaletteHorizontalArrowViaFirstResponderKeyDown(
        keyCode: UInt16,
        firstResponderIsCommandPaletteFieldEditor: Bool,
        firstResponderHasMarkedText: Bool = false
    ) -> Bool {
        guard firstResponderIsCommandPaletteFieldEditor else { return false }
        guard !firstResponderHasMarkedText else { return false }
        guard keyCode == 123 || keyCode == 124 else { return false }

        let normalizedFlags = firstResponderKeyRoutingNormalized
        switch normalizedFlags {
        case [], [.shift], [.option], [.option, .shift], [.command], [.command, .shift]:
            return true
        default:
            return false
        }
    }

    /// Whether an arrow keyDown belongs to a focused standalone editable text
    /// responder (text-box input, file-preview editor, …) so it should be
    /// forwarded to `firstResponder.keyDown` rather than swallowed by the original
    /// `NSWindow.performKeyEquivalent`.
    ///
    /// Owns the four arrows (keyCodes 123–126) for the modifier combos a text
    /// editor handles itself: plain (move), Shift (extend selection), Option
    /// (word/paragraph), and Command (line/document boundary) plus their Shift
    /// combos. Cmd+Option+Arrow is excluded so it still reaches cmux's pane-focus
    /// shortcuts. Marked text (IME composition) is left to the input method.
    private func standaloneTextResponderOwnsArrowKeyDown(
        keyCode: UInt16,
        firstResponderHasMarkedText: Bool
    ) -> Bool {
        guard !firstResponderHasMarkedText else { return false }
        guard (123...126).contains(keyCode) else { return false }

        let normalizedFlags = firstResponderKeyRoutingNormalized
        switch normalizedFlags {
        case [], [.shift], [.option], [.option, .shift], [.command], [.command, .shift]:
            return true
        default:
            return false
        }
    }

    public func shouldDispatchTextBoxInputArrowViaFirstResponderKeyDown(
        keyCode: UInt16,
        firstResponderIsTextBoxInput: Bool,
        firstResponderHasMarkedText: Bool = false
    ) -> Bool {
        guard firstResponderIsTextBoxInput else { return false }
        return standaloneTextResponderOwnsArrowKeyDown(
            keyCode: keyCode,
            firstResponderHasMarkedText: firstResponderHasMarkedText
        )
    }

    /// Whether an arrow keyDown should be forwarded straight to the focused
    /// standalone editable text view instead of falling through to the original
    /// `NSWindow.performKeyEquivalent`, which swallows plain arrows before the
    /// view's `keyDown` runs.
    ///
    /// This generalizes the per-surface arrow-forwarding seam (browser, omnibar,
    /// command palette, text-box input) to cover the whole class of standalone
    /// editable `NSTextView`s cmux hosts, the file-preview editor today, any
    /// future one tomorrow. Field editors (the omnibar / command-palette / find
    /// field editors) are excluded by the caller because they have their own
    /// dedicated routing or work through the normal field-editor path. Shares the
    /// keyCode/modifier policy with ``shouldDispatchTextBoxInputArrowViaFirstResponderKeyDown(keyCode:firstResponderIsTextBoxInput:firstResponderHasMarkedText:)``
    /// via ``standaloneTextResponderOwnsArrowKeyDown(keyCode:firstResponderHasMarkedText:)``.
    public func shouldDispatchEditableTextViewArrowViaFirstResponderKeyDown(
        keyCode: UInt16,
        firstResponderIsEditableTextView: Bool,
        firstResponderHasMarkedText: Bool = false
    ) -> Bool {
        guard firstResponderIsEditableTextView else { return false }
        return standaloneTextResponderOwnsArrowKeyDown(
            keyCode: keyCode,
            firstResponderHasMarkedText: firstResponderHasMarkedText
        )
    }

    /// Ctrl-N / Ctrl-P navigate the mention-completion popover (and emacs-style line
    /// movement) inside the terminal textbox. Like plain arrows, the window's
    /// `performKeyEquivalent` claims these before they reach the textbox `keyDown`, so
    /// they must be routed to the first responder explicitly. Scoped to the textbox so
    /// terminal/browser Ctrl-N/Ctrl-P are unaffected.
    public func shouldDispatchTextBoxInputControlNavViaFirstResponderKeyDown(
        charactersIgnoringModifiers: String?,
        firstResponderIsTextBoxInput: Bool,
        firstResponderHasMarkedText: Bool = false
    ) -> Bool {
        guard firstResponderIsTextBoxInput else { return false }
        guard !firstResponderHasMarkedText else { return false }

        let normalizedFlags = firstResponderKeyRoutingNormalized
        guard normalizedFlags == [.control] else { return false }
        let key = charactersIgnoringModifiers?.lowercased()
        return key == "n" || key == "p"
    }
}
