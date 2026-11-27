import Foundation

/// Aggregate validation report for a set of custom sidebars.
public struct CustomSidebarValidationReport: Equatable, Sendable {
    /// Per-sidebar validation entries.
    public let entries: [CustomSidebarValidationEntry]

    /// Creates a validation report.
    public init(entries: [CustomSidebarValidationEntry]) {
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
