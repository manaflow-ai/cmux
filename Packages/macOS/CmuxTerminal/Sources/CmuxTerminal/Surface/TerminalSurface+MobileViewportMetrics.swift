extension TerminalSurface {
    @MainActor
    func recordMobileViewportCellLimit(columns: Int, rows: Int) {
        nextMobileViewportCellLimitGeneration &+= 1
        mobileViewportCellLimit = MobileViewportCellLimit(
            generation: nextMobileViewportCellLimitGeneration,
            columns: max(1, columns),
            rows: max(1, rows)
        )
    }

    /// Token attached to a queued cell-metrics callback from the current fit.
    @MainActor
    public var mobileViewportFontMetricsTransactionGeneration: UInt64? {
        mobileViewportMetricsReapplyState.activeTransactionGeneration
    }

    /// Reapplies the active mobile viewport after Ghostty changes cell metrics.
    /// A callback from an automatic fit resumes that fit's bounded transaction;
    /// unrelated metrics changes begin a fresh transaction.
    @MainActor
    public func mobileViewportFontMetricsDidChange(
        transactionGeneration: UInt64?
    ) {
        guard let mobileViewportCellLimit else { return }
        mobileViewportFontFitState.cellMetricsDidChange()
        _ = applyMobileViewportLimit(
            columns: mobileViewportCellLimit.columns,
            rows: mobileViewportCellLimit.rows,
            reason: "cell_metrics_changed",
            configuredFontPointSizeOverride: nil,
            authoritativeViewportUpdate: false,
            resumingMetricsTransaction: transactionGeneration
        )
    }
}
