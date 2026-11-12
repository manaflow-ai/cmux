/// The page that keys typed ahead wait for: the focus they were typed in and the page's type-ahead
/// surface (its input readiness), which the key router keeps while the queue holds text.
///
/// ```swift
/// let wait = TypeAheadWait(focus: .agentPage(pane: "pane_a", tab: "pending_tab_1"), page: "readiness-1")
/// wait.survives(.agentPage(pane: "pane_a", tab: "tab_1"), page: "readiness-1") // the same page
/// ```
public nonisolated struct TypeAheadWait: Equatable, Sendable {
    /// The focus the keys were typed in.
    public var focus: FocusState.Resolved
    /// The type-ahead surface of the page they wait for.
    public var page: String

    /// - Parameters:
    ///   - focus: The focus the keys were typed in.
    ///   - page: The type-ahead surface of the page they wait for.
    public init(focus: FocusState.Resolved, page: String) {
        self.focus = focus
        self.page = page
    }

    /// Whether the keys still wait once focus settled at `settled`, whose page has the type-ahead
    /// surface `settledPage` (nil when it shows no page).
    ///
    /// - Parameters:
    ///   - settled: The focus that settled.
    ///   - settledPage: The type-ahead surface of the page `settled` names, if any.
    /// - Returns: False when focus moved off the page: the queue is dropped.
    public func survives(_ settled: FocusState.Resolved, page settledPage: String?) -> Bool {
        settled == focus
    }
}
