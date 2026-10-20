import Foundation

/// The aggregate result of a browser import: the source browser, the requested
/// scope and domain filters, any cmux profiles created, and the per-mapping
/// outcome entries.
public struct BrowserImportOutcome: Sendable {
    /// Display name of the source browser.
    public let browserName: String
    /// The scope of data that was imported.
    public let scope: BrowserImportScope
    /// Domain filters applied during the import (empty means no filtering).
    public let domainFilters: [String]
    /// Display names of cmux profiles created during this import.
    public let createdDestinationProfileNames: [String]
    /// Per-mapping import outcome entries.
    public let entries: [BrowserImportOutcomeEntry]
    /// De-duplicated warnings aggregated across all entries.
    public let warnings: [String]

    /// Creates an import outcome.
    ///
    /// - Parameters:
    ///   - browserName: Display name of the source browser.
    ///   - scope: The scope of data that was imported.
    ///   - domainFilters: Domain filters applied during the import.
    ///   - createdDestinationProfileNames: Names of cmux profiles created.
    ///   - entries: Per-mapping import outcome entries.
    ///   - warnings: Aggregated warnings across all entries.
    public init(
        browserName: String,
        scope: BrowserImportScope,
        domainFilters: [String],
        createdDestinationProfileNames: [String],
        entries: [BrowserImportOutcomeEntry],
        warnings: [String]
    ) {
        self.browserName = browserName
        self.scope = scope
        self.domainFilters = domainFilters
        self.createdDestinationProfileNames = createdDestinationProfileNames
        self.entries = entries
        self.warnings = warnings
    }

    /// Total cookies imported across all entries.
    public var totalImportedCookies: Int {
        entries.reduce(0) { $0 + $1.importedCookies }
    }

    /// Total cookies skipped across all entries.
    public var totalSkippedCookies: Int {
        entries.reduce(0) { $0 + $1.skippedCookies }
    }

    /// Total history entries imported across all entries.
    public var totalImportedHistoryEntries: Int {
        entries.reduce(0) { $0 + $1.importedHistoryEntries }
    }

    /// JSON-serializable representation sent over the cmux automation socket.
    public var socketPayload: [String: Any] {
        [
            "browser": browserName,
            "scope": scope.rawValue,
            "domain_filters": domainFilters,
            "created_destination_profiles": createdDestinationProfileNames,
            "imported_cookies": totalImportedCookies,
            "skipped_cookies": totalSkippedCookies,
            "imported_history_entries": totalImportedHistoryEntries,
            "warnings": warnings,
            "entries": entries.map { entry in
                [
                    "source_profiles": entry.sourceProfileNames,
                    "destination_profile": entry.destinationProfileName,
                    "imported_cookies": entry.importedCookies,
                    "skipped_cookies": entry.skippedCookies,
                    "imported_history_entries": entry.importedHistoryEntries,
                    "warnings": entry.warnings,
                ] as [String: Any]
            },
        ]
    }
}
