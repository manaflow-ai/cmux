struct TerminalPortalReconciliationReasons: OptionSet {
    let rawValue: UInt8

    static let bindingRequired = Self(rawValue: 1 << 0)
    static let flushPendingManualSizeReport = Self(rawValue: 1 << 1)
}

