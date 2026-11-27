import Foundation

/// The result of importing one source-to-destination mapping: how many cookies
/// and history entries were imported or skipped, plus any warnings.
public struct BrowserImportOutcomeEntry: Sendable {
    /// Display names of the source profiles that were read.
    public let sourceProfileNames: [String]
    /// Display name of the cmux destination profile that was written.
    public let destinationProfileName: String
    /// Number of cookies successfully imported.
    public let importedCookies: Int
    /// Number of cookies skipped (for example, undecryptable encrypted values).
    public let skippedCookies: Int
    /// Number of history entries imported.
    public let importedHistoryEntries: Int
    /// Human-readable warnings produced while importing this entry.
    public let warnings: [String]

    /// Creates an import-outcome entry.
    ///
    /// - Parameters:
    ///   - sourceProfileNames: Display names of the source profiles read.
    ///   - destinationProfileName: Display name of the destination profile.
    ///   - importedCookies: Number of cookies successfully imported.
    ///   - skippedCookies: Number of cookies skipped.
    ///   - importedHistoryEntries: Number of history entries imported.
    ///   - warnings: Warnings produced while importing this entry.
    public init(
        sourceProfileNames: [String],
        destinationProfileName: String,
        importedCookies: Int,
        skippedCookies: Int,
        importedHistoryEntries: Int,
        warnings: [String]
    ) {
        self.sourceProfileNames = sourceProfileNames
        self.destinationProfileName = destinationProfileName
        self.importedCookies = importedCookies
        self.skippedCookies = skippedCookies
        self.importedHistoryEntries = importedHistoryEntries
        self.warnings = warnings
    }
}
