extension CmuxConfigSnapshot {
    /// `diagnostics.usageRecording` (``UsageRecordingSetting``).
    public var usageRecording: Bool { UsageRecordingSetting().value(in: root) }
}
