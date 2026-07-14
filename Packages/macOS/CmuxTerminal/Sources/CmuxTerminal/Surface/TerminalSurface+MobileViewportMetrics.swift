extension TerminalSurface {
    /// Reapplies the active mobile viewport after Ghostty changes cell metrics.
    /// Synchronous callbacks caused by the fit itself only rearm the live-font
    /// probe; the bounded fit already in progress owns their convergence.
    @MainActor
    public func mobileViewportFontMetricsDidChange() {
        mobileViewportFontMetricsDidChange { [unowned self] columns, rows in
            _ = applyMobileViewportLimit(
                columns: columns,
                rows: rows,
                reason: "cell_metrics_changed"
            )
        }
    }

    @MainActor
    func mobileViewportFontMetricsDidChange(
        reapply: (_ columns: Int, _ rows: Int) -> Void
    ) {
        guard let mobileViewportCellLimit else { return }
        mobileViewportFontFitState.cellMetricsDidChange()
        mobileViewportMetricsReapplyState.cellMetricsDidChange {
            reapply(mobileViewportCellLimit.columns, mobileViewportCellLimit.rows)
        }
    }
}
