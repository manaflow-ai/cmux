/// What a cmux window does when a window other than itself becomes key
/// (`FocusEffectApplier.childWindowDidBecomeKey`), and whether it takes the
/// keys back from a key Chromium page window (`reclaimKeyFromPageWindow`).
/// Pure, so the input model runs the same rule as the applier. The rule is
/// `cmux-focus-core`'s `child_window`; these are its value types.
public nonisolated struct ChildWindowKeyRule {
    public nonisolated init() {}
    /// The key window's relation to this cmux window.
    public enum Parent: Equatable, Sendable, Codable {
        /// A child window of this cmux window.
        case thisWindow
        /// No parent window: a page window Chromium showed or activated
        /// before (or while) the fork placed it as a child.
        case none
        /// A child of another window.
        case other
    }

    /// What the rule knows about the key window.
    public struct Facts: Equatable, Sendable, Codable {
        /// Its relation to this cmux window.
        public var parent: Parent
        /// It is an `NSPanel` (the palette, a bubble).
        public var isPanel = false
        /// `CefNSWindow`: a Chromium page window (or docked DevTools).
        public var isChromiumPage: Bool
        /// The window is a docked DevTools of a pane of this window.
        public var isDevTools = false
        /// A mouse press made it key.
        public var clicked = false
        /// Its frame is over a pane that shows a Chromium page.
        public var overPane = false
        /// This cmux window is the active one (the last one the user used).
        public var thisWindowIsActive = true

        /// The facts of one key window; the defaults describe a plain page window of the active window.
        ///
        /// - Parameters:
        ///   - parent: Its relation to this cmux window.
        ///   - isPanel: It is an `NSPanel`.
        ///   - isChromiumPage: It is a `CefNSWindow`.
        ///   - isDevTools: It is a docked DevTools of a pane of this window.
        ///   - clicked: A mouse press made it key.
        ///   - overPane: Its frame is over a pane that shows a Chromium page.
        ///   - thisWindowIsActive: This cmux window is the active one.
        public init(parent: Parent, isPanel: Bool = false, isChromiumPage: Bool, isDevTools: Bool = false,
                    clicked: Bool = false, overPane: Bool = false, thisWindowIsActive: Bool = true) {
            self.parent = parent
            self.isPanel = isPanel
            self.isChromiumPage = isChromiumPage
            self.isDevTools = isDevTools
            self.clicked = clicked
            self.overPane = overPane
            self.thisWindowIsActive = thisWindowIsActive
        }
    }

    /// What this window does about the key window.
    public enum Decision: Equatable, Sendable, Codable {
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

    /// The decision for a window other than this one that became key.
    ///
    /// - Parameter facts: What is known about the key window.
    /// - Returns: What this window does (``Decision/ignore`` when the rule does not answer).
    public static func decide(_ facts: Facts) -> Decision {
        answer(facts)?.decision ?? .ignore
    }

    /// Whether this window takes the keys back from the key window `facts`
    /// describes, when its target is not a page.
    ///
    /// - Parameter facts: What is known about the key window.
    /// - Returns: Whether this window makes itself key again.
    public static func shouldReclaim(_ facts: Facts) -> Bool {
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
