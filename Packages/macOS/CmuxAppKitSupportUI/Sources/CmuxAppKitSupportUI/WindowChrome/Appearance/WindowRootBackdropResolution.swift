/// Root backdrop resolution returned when a pane-local color is present.
public struct WindowRootBackdropResolution {
    /// Snapshot that remains authoritative for the root backdrop.
    public let snapshot: WindowAppearanceSnapshot

    /// Debug source label.
    public let source: String

    /// Pane-local override hex value, or `"nil"`.
    public let overrideHex: String

    /// Creates a root backdrop resolution.
    public init(snapshot: WindowAppearanceSnapshot, source: String, overrideHex: String) {
        self.snapshot = snapshot
        self.source = source
        self.overrideHex = overrideHex
    }
}
