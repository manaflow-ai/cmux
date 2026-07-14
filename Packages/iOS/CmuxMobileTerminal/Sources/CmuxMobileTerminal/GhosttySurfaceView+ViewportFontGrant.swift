#if canImport(UIKit)
import CmuxMobileDiagnostics

@MainActor
extension GhosttySurfaceView {
    /// Re-arms a viewport report after a missing effective-grid reply.
    ///
    /// Retries are display-link driven and bounded. A final failure blocks the
    /// matching larger-font grant until geometry produces a different request.
    ///
    /// - Parameter reportID: The identifier of the viewport report that failed.
    public func retryViewportReport(reportID: UInt64) {
        guard viewportReportAuthority.owns(reportID) else {
            let latest = viewportReportAuthority.currentID.map(String.init) ?? "none"
            MobileDebugLog.anchormux(
                "zoom.viewport.staleRetry id=\(reportID) latest=\(latest)"
            )
            return
        }
        let canRetry = viewportReportRetries < Self.maxViewportReportRetries &&
            lastReportedSize.map { $0.columns > 0 && $0.rows > 0 } == true
        viewportFontGrantState.noteReportFailure(reportID: reportID, willRetry: canRetry)
        guard canRetry, let pending = lastReportedSize else { return }
        viewportReportRetries += 1
        MobileDebugLog.anchormux(
            "zoom.viewport.retry \(viewportReportRetries)/\(Self.maxViewportReportRetries) "
            + "grid=\(pending.columns)x\(pending.rows)"
        )
        pendingViewportReport = pending
        viewportReportSettleFrames = 0
    }

    /// Applies a destination font only after its bound report is acknowledged.
    func applyAcknowledgedViewportFontGrant(cols: Int, rows: Int, reportID: UInt64) {
        let awaitedGrant = viewportFontGrantState.isAwaitingAcknowledgement(reportID: reportID)
        if let fontSize = viewportFontGrantState.consumeAcknowledgement(
            reportID: reportID,
            columns: cols,
            rows: rows
        ) {
            MobileDebugLog.anchormux(
                "zoom.viewport.fontGrant id=\(reportID) grid=\(cols)x\(rows) font=\(fontSize)"
            )
            applyAbsoluteFontSize(fontSize)
        } else if awaitedGrant {
            MobileDebugLog.anchormux(
                "zoom.viewport.fontGrantRejected id=\(reportID) grid=\(cols)x\(rows)"
            )
            viewportFontGrantState.noteReportFailure(reportID: reportID, willRetry: false)
        }
    }
}
#endif
