public enum MobileTerminalScrollbackBudget {
    /// Maximum primary-screen scrollback rows a mobile full replay asks the
    /// Mac to send. iOS mirrors this exact window locally so primary-screen
    /// drag/deceleration can stay phone-local without silently becoming
    /// "whatever Ghostty happened to retain".
    public static let fullReplayRows = 10_000

    /// Small fallback used when an older client asks for replay without an
    /// explicit scrollback window.
    public static let defaultReplayRows = 240

    /// Bounded repair window for host-coupled scroll responses. The decoupled
    /// primary-screen path should not depend on this during normal iPhone
    /// scrolling.
    public static let scrollPrefetchRows = 600

    /// Conservative local-memory estimate for one styled Ghostty scrollback
    /// row. This intentionally overestimates plain live-tail rows so the mirror
    /// retains the whole bounded replay window instead of truncating around
    /// line 0703 under the default 10 MB Ghostty limit.
    public static let localMirrorBytesPerReplayRow = 12 * 1024

    /// Per-surface iOS Ghostty scrollback byte budget. Derived from
    /// ``fullReplayRows`` so the renderer's retention capability and the RPC
    /// replay window move together.
    public static let localMirrorScrollbackLimitBytes =
        fullReplayRows * localMirrorBytesPerReplayRow
}

public enum MobileTerminalScrollbackReplayRequest {
    public static let scopeParameter = "scrollback_scope"
    public static let fullScope = "full"
}
