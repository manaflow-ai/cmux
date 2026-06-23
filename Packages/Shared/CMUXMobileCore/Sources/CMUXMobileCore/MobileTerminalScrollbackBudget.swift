public struct MobileTerminalScrollbackMirrorBudget: Equatable, Sendable {
    /// Maximum primary-screen scrollback rows a mobile full replay asks the Mac
    /// to send.
    public let fullReplayRows: Int

    /// Small fallback used when an older client asks for replay without an
    /// explicit scrollback window.
    public let defaultReplayRows: Int

    /// Bounded repair window for host-coupled scroll responses. The decoupled
    /// primary-screen path should not depend on this during normal iPhone
    /// scrolling.
    public let scrollPrefetchRows: Int

    /// Conservative local-memory estimate for one styled Ghostty scrollback
    /// row. This intentionally overestimates plain live-tail rows so the mirror
    /// retains the whole bounded replay window instead of truncating around
    /// line 0703 under the default 10 MB Ghostty limit.
    public let localMirrorBytesPerReplayRow: Int

    /// Ghostty can report one retained row less than the replay+viewport count
    /// while still serving the entire requested scrollback window. Treat that as
    /// accounting noise, not data loss.
    public let retentionAccountingSlackRows: UInt64

    public init(
        fullReplayRows: Int,
        defaultReplayRows: Int,
        scrollPrefetchRows: Int,
        localMirrorBytesPerReplayRow: Int,
        retentionAccountingSlackRows: UInt64
    ) {
        self.fullReplayRows = max(0, fullReplayRows)
        self.defaultReplayRows = max(0, defaultReplayRows)
        self.scrollPrefetchRows = max(0, scrollPrefetchRows)
        self.localMirrorBytesPerReplayRow = max(1, localMirrorBytesPerReplayRow)
        self.retentionAccountingSlackRows = retentionAccountingSlackRows
    }

    /// Per-surface iOS Ghostty scrollback byte budget. Derived from
    /// ``fullReplayRows`` so the renderer's retention capability and the RPC
    /// replay window move together.
    public var localMirrorScrollbackLimitBytes: Int {
        fullReplayRows * localMirrorBytesPerReplayRow
    }

    public func expectedTotalRows(scrollbackRows: Int, visibleRows: UInt64) -> UInt64 {
        UInt64(max(0, scrollbackRows)) + visibleRows
    }
}

public enum MobileTerminalScrollbackBudget {
    /// One shared contract for the Mac replay window, iOS Ghostty retention, and
    /// local scrollback model. Keep all exported constants below as projections
    /// of this value so the three surfaces cannot drift independently.
    public static let localMirror = MobileTerminalScrollbackMirrorBudget(
        fullReplayRows: 10_000,
        defaultReplayRows: 240,
        scrollPrefetchRows: 600,
        localMirrorBytesPerReplayRow: 12 * 1024,
        retentionAccountingSlackRows: 1
    )

    public static let fullReplayRows = localMirror.fullReplayRows
    public static let defaultReplayRows = localMirror.defaultReplayRows
    public static let scrollPrefetchRows = localMirror.scrollPrefetchRows
    public static let localMirrorBytesPerReplayRow = localMirror.localMirrorBytesPerReplayRow
    public static let localMirrorScrollbackLimitBytes = localMirror.localMirrorScrollbackLimitBytes
    public static let retentionAccountingSlackRows = localMirror.retentionAccountingSlackRows
}

public enum MobileTerminalScrollbackReplayRequest {
    public static let scopeParameter = "scrollback_scope"
    public static let fullScope = "full"
}
