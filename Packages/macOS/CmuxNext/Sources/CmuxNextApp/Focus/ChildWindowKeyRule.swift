/// What a cmux window does when a window other than itself becomes key
/// (`FocusEffectApplier.childWindowDidBecomeKey`), and whether it takes the
/// keys back from a key Chromium page window (`reclaimKeyFromPageWindow`).
/// Pure, so the input model runs the same rule as the applier.
nonisolated enum ChildWindowKeyRule {
    /// The key window's relation to this cmux window.
    enum Parent: Equatable, Sendable {
        case thisWindow
        /// No parent window: a page window Chromium showed or activated
        /// before (or while) the fork placed it as a child.
        case none
        case other
    }

    struct Facts: Equatable, Sendable {
        var parent: Parent
        var isPanel = false
        /// `CefNSWindow`: a Chromium page window (or docked DevTools).
        var isChromiumPage: Bool
        /// The window is a docked DevTools of a pane of this window.
        var isDevTools = false
        /// A mouse press made it key.
        var clicked = false
        /// Its frame is over a pane that shows a Chromium page.
        var overPane = false
        /// This cmux window is the active one (the last one the user used).
        var thisWindowIsActive = true
    }

    enum Decision: Equatable, Sendable {
        /// Not this window's business.
        case ignore
        /// A click into docked DevTools: the tools have the keyboard.
        case devTools
        /// A page window took the keys without the user choosing it: the
        /// model re-applies its target, which takes the keys back unless
        /// the target is that page.
        case unchosenPage
        /// A click into a placed page chose it.
        case chosenPage
        /// Another owned window over a pane became key without a click
        /// (an extension popup): the model re-applies its target.
        case reapply
    }

    static func decide(_ facts: Facts) -> Decision {
        guard isOurs(facts) else { return .ignore }
        if facts.isDevTools { return .devTools }
        if facts.isChromiumPage, !facts.clicked || !facts.overPane { return .unchosenPage }
        guard facts.overPane else { return .ignore }
        return facts.clicked ? .chosenPage : .reapply
    }

    /// Whether this window takes the keys back from the key window `facts`
    /// describes, when its target is not a page.
    static func shouldReclaim(_ facts: Facts) -> Bool {
        isOurs(facts)
    }

    /// A child of this window, or a parentless Chromium page window while
    /// this window is the active one: the fork hides and unparents a page
    /// whose parent view has no bounds or is hidden, and an activation then
    /// shows and keys it before the fork makes it a child again
    /// (input-spec.md B13). Only the active window answers for it, so two
    /// windows never both take the keys back.
    private static func isOurs(_ facts: Facts) -> Bool {
        guard !facts.isPanel else { return false }
        switch facts.parent {
        case .thisWindow: return true
        case .none: return facts.isChromiumPage && facts.thisWindowIsActive
        case .other: return false
        }
    }
}
