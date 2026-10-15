/// What a cmux main window knows about another window that became key, and
/// what it does about it.
///
/// The cmux Chromium fork shows each page in its own `CefNSWindow`, placed as
/// a child window over the panel's host view. Chromium makes that window key
/// on its own (after every navigation it starts, when a popup shows), which
/// would take the keyboard from the address bar of a new panel or from the
/// terminal the user is typing in. Only a click into the page chooses it.
///
/// Pure. Ported from cmux Next (`cmux-focus-core/src/child_window.rs`,
/// `CmuxNextApp/Focus/ChildWindowKeyRule.swift`).
public struct ChromiumKeyWindowFacts: Equatable, Sendable {
    /// The key window's relation to this cmux window.
    public enum Parent: Equatable, Sendable {
        case thisWindow
        /// No parent window: a page window Chromium showed or activated
        /// before (or while) the fork placed it as a child.
        case none
        case other
    }

    /// What this window does.
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

    /// What this window does about the key window.
    public var decision: Decision {
        guard isOurs else { return .ignore }
        if isDevTools { return .devTools }
        if isChromiumPage, !clicked || !overPane { return .unchosenPage }
        guard overPane else { return .ignore }
        return clicked ? .chosenPage : .reapply
    }

    /// Whether this window takes the keys back from the key window, when its
    /// focused target is not a page.
    public var shouldReclaim: Bool { isOurs }

    /// A child of this window, or a parentless Chromium page window while
    /// this window is the active one. Only the active window answers for a
    /// parentless page, so two windows never both take the keys back.
    private var isOurs: Bool {
        guard !isPanel else { return false }
        switch parent {
        case .thisWindow: return true
        case .none: return isChromiumPage && thisWindowIsActive
        case .other: return false
        }
    }
}
