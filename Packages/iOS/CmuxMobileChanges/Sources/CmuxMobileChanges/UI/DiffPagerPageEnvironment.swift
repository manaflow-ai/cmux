public import Observation

/// Live values shared by mounted pager pages.
///
/// Observation scopes invalidation to the page subtrees that read these
/// properties (a pinch re-renders mounted pages, a settle re-renders the two
/// pages whose selection gating changed); the paging container itself never
/// reads them, so it stays untouched.
@MainActor
@Observable
public final class DiffPagerPageEnvironment {
    /// Current live diff font size, updated continuously during a pinch.
    public var fontSize: Double
    /// Selected page index, updated when a page transition completes.
    public var selectedIndex: Int

    /// Creates the shared page environment.
    /// - Parameters:
    ///   - fontSize: Persisted font size snapshot.
    ///   - selectedIndex: File index opened from the list.
    public init(fontSize: Double, selectedIndex: Int) {
        self.fontSize = fontSize
        self.selectedIndex = selectedIndex
    }
}
