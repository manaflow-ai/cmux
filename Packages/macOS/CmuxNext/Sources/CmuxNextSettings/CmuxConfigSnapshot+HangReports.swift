extension CmuxConfigSnapshot {
    /// `diagnostics.hangReports` (``HangReportsSetting``).
    public var hangReports: Bool { HangReportsSetting().value(in: root) }
}
