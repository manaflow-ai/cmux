public enum MobileTerminalScrollbackBudget {
    /// Small fallback used when an older client asks for replay without an
    /// explicit scrollback window.
    public static let defaultReplayRows = 240

    /// Bounded repair window for host-coupled scroll responses. The decoupled
    /// primary-screen path should not depend on this during normal iPhone
    /// scrolling.
    public static let scrollPrefetchRows = 600
}

public enum MobileTerminalScrollbackReplayRequest {
    public static let scopeParameter = "scrollback_scope"
    public static let fullScope = "full"
}
