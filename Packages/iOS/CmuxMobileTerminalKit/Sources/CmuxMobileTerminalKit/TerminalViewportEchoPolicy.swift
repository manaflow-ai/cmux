/// Matches daemon viewport replies to the local natural-grid reports that produced them.
public struct TerminalViewportEchoPolicy: Sendable {
    /// Creates a terminal viewport echo policy.
    public init() {}

    /// Decide whether an identified viewport reply is still current.
    ///
    /// When request identity is available, an older reply must not overwrite the
    /// effective grid computed for the latest natural-grid report. Unidentified
    /// replies remain accepted for legacy call sites.
    ///
    /// - Parameters:
    ///   - latestReport: The latest local natural grid reported to the daemon.
    ///   - reportedGrid: The natural grid attached to this daemon reply, or
    ///     `nil` when the caller cannot identify it.
    /// - Returns: True when the reply may update effective-grid state.
    public func responseMatchesLatestReport(
        latestReport: (columns: Int, rows: Int)?,
        reportedGrid: (columns: Int, rows: Int)?
    ) -> Bool {
        guard let latestReport, let reportedGrid else { return true }
        return latestReport.columns == reportedGrid.columns &&
            latestReport.rows == reportedGrid.rows
    }

    /// Decide whether a viewport reply should clear the pending echo guard.
    ///
    /// A response identified with the natural grid that produced it must match
    /// the pending local grid. Unidentified responses preserve the legacy
    /// behavior for call sites that cannot carry request identity.
    ///
    /// - Parameters:
    ///   - pendingEcho: The local natural grid currently waiting for a daemon reply.
    ///   - reportedGrid: The natural grid attached to this daemon reply, or
    ///     `nil` when the caller cannot identify it.
    /// - Returns: True when the pending echo can be cleared.
    public func responseClearsPendingEcho(
        pendingEcho: (columns: Int, rows: Int)?,
        reportedGrid: (columns: Int, rows: Int)?
    ) -> Bool {
        guard let pendingEcho else { return false }
        guard let reportedGrid else { return true }
        return pendingEcho.columns == reportedGrid.columns &&
            pendingEcho.rows == reportedGrid.rows
    }

    /// Decide whether a viewport reply should reset retry accounting.
    ///
    /// Replies with no pending echo are current by definition. When a pending
    /// echo exists, only the reply for that same natural grid confirms the
    /// current round trip; older identified replies must leave retry state intact.
    ///
    /// - Parameters:
    ///   - pendingEcho: The local natural grid currently waiting for a daemon reply.
    ///   - reportedGrid: The natural grid attached to this daemon reply, or
    ///     `nil` when the caller cannot identify it.
    /// - Returns: True when viewport retry accounting can be reset.
    public func responseResetsRetryCount(
        pendingEcho: (columns: Int, rows: Int)?,
        reportedGrid: (columns: Int, rows: Int)?
    ) -> Bool {
        pendingEcho == nil ||
            responseClearsPendingEcho(pendingEcho: pendingEcho, reportedGrid: reportedGrid)
    }
}
