/// What a cmux main window does when another window becomes key, and whether
/// it takes the keyboard back from a key Chromium page window.
///
/// The cmux Chromium fork shows each page in its own `CefNSWindow`, placed as
/// a child window over the panel's host view. Chromium makes that window key
/// on its own (after every navigation it starts, when a popup shows), which
/// would take the keyboard from the address bar of a new panel or from the
/// terminal the user is typing in. Only a click into the page chooses it.
///
/// Pure. Ported from cmux Next (`cmux-focus-core/src/child_window.rs`,
/// `CmuxNextApp/Focus/ChildWindowKeyRule.swift`).
public enum ChromiumKeyWindowRule {
    /// The key window's relation to this cmux window.
    public enum Parent: Equatable, Sendable {
        case thisWindow
        /// No parent window: a page window Chromium showed or activated
        /// before (or while) the fork placed it as a child.
        case none
        case other
    }

    public struct Facts: Equatable, Sendable {
        public var parent: Parent
        /// An `NSPanel` (a sheet, a popover window): never a page.
        public var isPanel: Bool
        /// `CefNSWindow`: a Chromium page window (or docked DevTools).
        public var isChromiumPage: Bool
        /// The window is a docked DevTools of a panel of this window.
        public var isDevTools: Bool
        /// A mouse press made it key.
        public var clicked: Bool
        /// Its frame is over a panel that shows a Chromium page.
        public var overPane: Bool
        /// This cmux window is the active one (the last one the user used).
        public var thisWindowIsActive: Bool

        public init(
            parent: Parent,
            isPanel: Bool = false,
            isChromiumPage: Bool,
            isDevTools: Bool = false,
            clicked: Bool = false,
            overPane: Bool = false,
            thisWindowIsActive: Bool = true
        ) {
            self.parent = parent
            self.isPanel = isPanel
            self.isChromiumPage = isChromiumPage
            self.isDevTools = isDevTools
            self.clicked = clicked
            self.overPane = overPane
            self.thisWindowIsActive = thisWindowIsActive
        }
    }

    public enum Decision: Equatable, Sendable {
        /// Not this window's business.
        case ignore
        /// A click into docked DevTools: the tools have the keyboard.
        case devTools
        /// A page window took the keyboard without the user choosing it:
        /// the window gives it back to its focused target (the address bar,
        /// a terminal) unless that target is the page.
        case unchosenPage
        /// A click into a placed page chose it: the page is focused.
        case chosenPage
        /// Another owned window over a panel became key without a click (an
        /// extension popup): the window re-applies its focused target.
        case reapply
    }

    public static func decide(_ facts: Facts) -> Decision {
        guard isOurs(facts) else { return .ignore }
        if facts.isDevTools { return .devTools }
        if facts.isChromiumPage, !facts.clicked || !facts.overPane { return .unchosenPage }
        guard facts.overPane else { return .ignore }
        return facts.clicked ? .chosenPage : .reapply
    }

    /// Whether this window takes the keys back from the key window `facts`
    /// describes, when its focused target is not a page.
    public static func shouldReclaim(_ facts: Facts) -> Bool {
        isOurs(facts)
    }

    /// A child of this window, or a parentless Chromium page window while
    /// this window is the active one. Only the active window answers for a
    /// parentless page, so two windows never both take the keys back.
    private static func isOurs(_ facts: Facts) -> Bool {
        guard !facts.isPanel else { return false }
        switch facts.parent {
        case .thisWindow: return true
        case .none: return facts.isChromiumPage && facts.thisWindowIsActive
        case .other: return false
        }
    }
}
