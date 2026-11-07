extension CmuxConfigSnapshot {
    /// `diagnostics.usageRecording` (``UsageRecordingSetting``).
    public var usageRecording: Bool { UsageRecordingSetting().value(in: root) }
    /// `diagnostics.usageSharing` (``UsageSharingSetting``).
    public var usageSharing: Bool { UsageSharingSetting().value(in: root) }
}
