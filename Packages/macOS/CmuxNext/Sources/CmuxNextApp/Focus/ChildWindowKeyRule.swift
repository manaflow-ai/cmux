/// What a cmux window does when a window other than itself becomes key
/// (`FocusEffectApplier.childWindowDidBecomeKey`), and whether it takes the
/// keys back from a key Chromium page window (`reclaimKeyFromPageWindow`).
/// Pure, so the input model runs the same rule as the applier. The rule is
/// `cmux-focus-core`'s `child_window`; these are its value types.
nonisolated enum ChildWindowKeyRule {
    /// The key window's relation to this cmux window.
    enum Parent: Equatable, Sendable, Codable {
        case thisWindow
        /// No parent window: a page window Chromium showed or activated
        /// before (or while) the fork placed it as a child.
        case none
        case other
    }

    struct Facts: Equatable, Sendable, Codable {
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

    enum Decision: Equatable, Sendable, Codable {
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
        answer(facts)?.decision ?? .ignore
    }

    /// Whether this window takes the keys back from the key window `facts`
    /// describes, when its target is not a page.
    static func shouldReclaim(_ facts: Facts) -> Bool {
        answer(facts)?.shouldReclaim ?? false
    }

    private struct Answer: Decodable {
        var decision: Decision
        var shouldReclaim: Bool
    }

    private static func answer(_ facts: Facts) -> Answer? {
        struct Request: Encodable { var facts: Facts }
        let answer = FocusReducer.call("focus_child_window_key", Request(facts: facts), as: Answer.self)
        assert(answer != nil, "focus_child_window_key refused")
        return answer
    }
}
