/// One open of the New Tab page (CmuxNextApp's `NewTabSparePool.record`), for `debug.new_tab` (timing test,
/// plans/cmux-next/new-tab.md section 2.3).
public struct AgentPaneSpareOpening: Sendable {
    /// The open adopted the spare (else its page was made cold).
    public var spare: Bool
    /// The spare was parked in another window than the one it opened in.
    public var crossWindow: Bool
    /// Main-thread time from the open action to the page in its pane.
    public var milliseconds: Double
    /// The spare waited at another size than its pane's: the adoption resized it, and WebKit
    /// showed it at the old size until it laid it out again (the hqacp-v2 flash).
    public var refit = false

    public init(spare: Bool, crossWindow: Bool, milliseconds: Double, refit: Bool = false) {
        (self.spare, self.crossWindow, self.milliseconds, self.refit) = (spare, crossWindow, milliseconds, refit)
    }
}
