import Foundation

/// A resolved import plan: the destination mapping mode plus per-entry
/// source-to-destination mappings.
public struct BrowserImportExecutionPlan: Equatable, Sendable {
    /// How source profiles map onto destination profiles.
    public var mode: BrowserImportDestinationMode
    /// The individual source-to-destination mappings.
    public var entries: [BrowserImportExecutionEntry]

    /// Creates an import execution plan.
    ///
    /// - Parameters:
    ///   - mode: How source profiles map onto destination profiles.
    ///   - entries: The individual source-to-destination mappings.
    public init(mode: BrowserImportDestinationMode, entries: [BrowserImportExecutionEntry]) {
        self.mode = mode
        self.entries = entries
    }
}
