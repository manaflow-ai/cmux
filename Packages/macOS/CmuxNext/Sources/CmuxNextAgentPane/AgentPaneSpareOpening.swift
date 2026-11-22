/// One open of the New Tab page (CmuxNextApp's `NewTabSparePool.record`), for `debug.new_tab` (timing test,
/// plans/cmux-next/new-tab.md section 2.3).
public struct AgentPaneSpareOpening: Sendable {
    /// The open adopted the spare: the page that the pool made ahead. False for an idle page (`idle`) and for a
    /// page that was made cold.
    public var spare: Bool
    /// The open took an idle page: the page view of a New Tab tab that the person did not use (the tab that the pane
    /// left, or one that no window showed). No page was made and the pool gave none, so this is not `spare`: a
    /// reader that asks "did the pool's page serve this open" gets no for it.
    public var idle = false
    /// The spare was parked in another window than the one it opened in.
    public var crossWindow: Bool
    /// Main-thread time from the open action to the page in its pane.
    public var milliseconds: Double
    /// The spare waited at another size than its pane's: the adoption resized it, and WebKit
    /// showed it at the old size until it laid it out again (the hqacp-v2 flash).
    public var refit = false

    public init(spare: Bool, idle: Bool = false, crossWindow: Bool, milliseconds: Double, refit: Bool = false) {
        (self.spare, self.idle, self.crossWindow, self.milliseconds, self.refit) = (spare, idle, crossWindow, milliseconds, refit)
    }

    /// Milliseconds from `start` to now, as an opening records them.
    public static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let (seconds, attoseconds) = (ContinuousClock.now - start).components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }
}
