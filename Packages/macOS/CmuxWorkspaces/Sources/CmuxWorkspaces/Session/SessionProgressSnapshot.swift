/// A persisted workspace progress indicator inside a session snapshot.
///
/// A pure leaf value carrying the fractional progress `value` and an optional
/// `label`. The on-disk wire format is owned by the app's
/// `SessionTerminalPanelSnapshot`; encoding stays byte-identical to the legacy
/// app-target definition.
public struct SessionProgressSnapshot: Codable, Sendable {
    /// Fractional progress value.
    public var value: Double
    /// Optional label shown beside the progress indicator.
    public var label: String?

    /// Creates a persisted progress snapshot.
    public init(value: Double, label: String?) {
        self.value = value
        self.label = label
    }
}
