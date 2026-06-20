public import AppKit

/// Browser-omnibar keyboard-routing decisions, expressed as operations on the
/// event modifier state that drives them.
///
/// The cmux app target used to inline these as free functions in its shortcut
/// routing support file (`browserOmnibarSelectionDeltaForControlNavigation`,
/// `browserOmnibarShouldSubmitOnReturn`, and siblings). They are pure decisions
/// over a modifier-flag set plus the pressed key, with no AppKit responder,
/// `Workspace`, or `BrowserPanel` reach, so they belong in this package next to
/// the omnibar focus tracker and selection-repeat coordinator that consume them.
///
/// They are modeled as an extension on ``AppKit/NSEvent/ModifierFlags`` (the
/// type they operate on) rather than a static-method utility, so call sites read
/// `flags.browserOmnibar…` and no caseless namespace is introduced. The bodies
/// are byte-faithful lifts; the private normalization mirrors the app target's
/// `browserOmnibarNormalizedModifierFlags`, which stays in the app target for its
/// non-omnibar callers.
extension NSEvent.ModifierFlags {
    /// The modifier flags reduced to the device-independent set used for omnibar
    /// routing decisions, dropping the numeric-pad, function, and caps-lock bits.
    var browserOmnibarNormalized: NSEvent.ModifierFlags {
        intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
    }

    /// The omnibar selection move for a Control-navigation keystroke (Ctrl+N /
    /// Ctrl+P), or `nil` when the keystroke is not a Control-navigation move.
    /// - Parameters:
    ///   - hasFocusedAddressBar: Whether the omnibar address bar is focused.
    ///   - chars: The pressed characters (lowercased, layout-normalized).
    /// - Returns: `+1` for Ctrl+N, `-1` for Ctrl+P, otherwise `nil`.
    public func browserOmnibarSelectionDeltaForControlNavigation(
        hasFocusedAddressBar: Bool,
        chars: String
    ) -> Int? {
        guard hasFocusedAddressBar else { return nil }
        guard browserOmnibarNormalized == [.control] else { return nil }
        if chars == "n" { return 1 }
        if chars == "p" { return -1 }
        return nil
    }

    /// The omnibar selection move for an unmodified arrow keystroke, or `nil`
    /// when the keystroke is not a plain Down/Up arrow.
    /// - Parameters:
    ///   - hasFocusedAddressBar: Whether the omnibar address bar is focused.
    ///   - keyCode: The event key code.
    /// - Returns: `+1` for Down (125), `-1` for Up (126), otherwise `nil`.
    public func browserOmnibarSelectionDeltaForArrowNavigation(
        hasFocusedAddressBar: Bool,
        keyCode: UInt16
    ) -> Int? {
        guard hasFocusedAddressBar else { return nil }
        guard browserOmnibarNormalized == [] else { return nil }
        switch keyCode {
        case 125: return 1
        case 126: return -1
        default: return nil
        }
    }

    /// Whether shortcut routing should be bypassed because the omnibar is
    /// composing marked text (IME) and the keystroke is not Command-modified.
    /// - Parameters:
    ///   - hasFocusedAddressBar: Whether the omnibar address bar is focused.
    ///   - firstResponderHasMarkedText: Whether the omnibar field editor has
    ///     marked text in flight.
    /// - Returns: `true` when the keystroke must reach the text system instead
    ///   of cmux shortcut routing.
    public func browserOmnibarShouldBypassShortcutRoutingForMarkedText(
        hasFocusedAddressBar: Bool,
        firstResponderHasMarkedText: Bool
    ) -> Bool {
        guard hasFocusedAddressBar, firstResponderHasMarkedText else { return false }
        return !browserOmnibarNormalized.contains(.command)
    }

    /// Whether an in-flight Control-navigation selection repeat should continue
    /// for the current modifier state (only while Control alone is held).
    public var browserOmnibarShouldContinueControlNavigationRepeat: Bool {
        browserOmnibarNormalized == [.control]
    }

    /// Whether a Return/Enter keystroke should submit the omnibar (plain Return
    /// or Shift+Return); Command-modified Return is reserved for app shortcuts.
    public var browserOmnibarShouldSubmitOnReturn: Bool {
        let normalized = browserOmnibarNormalized
        return normalized == [] || normalized == [.shift]
    }
}
