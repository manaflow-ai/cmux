/// Custom-sidebar validation report shaped for control-socket command handling.
public struct ControlCustomSidebarValidationReport: Equatable, Sendable {
    /// Per-sidebar validation entries.
    public let entries: [ControlCustomSidebarValidationEntry]

    /// Creates a validation report.
    ///
    /// - Parameter entries: Per-sidebar validation entries.
    public init(entries: [ControlCustomSidebarValidationEntry]) {
        self.entries = entries
    }

    /// Number of valid entries.
    public var validCount: Int {
        entries.filter(\.isValid).count
    }

    /// Number of invalid entries.
    public var errorCount: Int {
        entries.count - validCount
    }

    /// Names of every sidebar included in the report.
    public var names: [String] {
        entries.map(\.name)
    }

    /// Names of sidebars that passed validation.
    public var validNames: [String] {
        entries.filter(\.isValid).map(\.name)
    }
}
