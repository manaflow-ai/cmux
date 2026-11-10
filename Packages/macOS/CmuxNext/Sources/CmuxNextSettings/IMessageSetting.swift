/// The iMessage connector's persisted choices. The connector is visible by default;
/// reading Messages starts only after the person's Connect click enables it.
nonisolated extension CmuxConfigSnapshot {
    /// The one opt-in shared by the app and the daemon; invalid values never enable reads.
    public var imessageEnabled: Bool {
        root.value(at: Self.imessageEnabledPath)?.boolValue ?? Self.imessageEnabledDefault
    }

    /// The walkthrough choice only; it grants neither Messages access nor permission to send.
    public var imessageAutomationSkipped: Bool {
        root.value(at: Self.imessageAutomationSkippedPath)?.boolValue ?? Self.imessageAutomationSkippedDefault
    }

    static func imessageDiagnostics(_ root: JSONValue) -> [SettingsDiagnostic] {
        [imessageEnabledPath, imessageAutomationSkippedPath].compactMap { path in
            guard let value = root.value(at: path), value.boolValue == nil else { return nil }
            return SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."), message: "expected true or false")
        }
    }
}
