public import Foundation

/// Everything read from one source profile, ready to save.
public struct ImportBatch: Sendable, Codable, Equatable {
    public var source: ImportSourceRecord
    public var bookmarks: [ImportedBookmark] = []
    public var history: [ImportedHistoryEntry] = []
    public var openTabs: [ImportedTab] = []
    public var extensions: [ImportedExtension] = []
    public var importedAt: Date

    public init(source: ImportSourceRecord, importedAt: Date = Date()) {
        self.source = source
        self.importedAt = importedAt
    }

    public var counts: ImportCounts {
        ImportCounts(bookmarks: bookmarks.count, history: history.count, openTabs: openTabs.count, extensions: extensions.count)
    }
}

/// Where one source profile's data went (data-model.md 5, `source_json`).
/// `targetProfileID` is the cmux browser profile that holds the data now
/// ("default" until browser profiles exist); `proposedProfileID` is the id
/// the source gets as its own browser profile, chosen once so an interrupted
/// or repeated import finds the same record.
public struct ImportSourceRecord: Sendable, Codable, Equatable, Hashable {
    public var browser: ImportBrowser
    public var profileDirectory: String
    public var displayName: String
    public var proposedProfileID: String
    public var targetProfileID: String

    public init(browser: ImportBrowser, profileDirectory: String, displayName: String, proposedProfileID: String, targetProfileID: String) {
        self.browser = browser
        self.profileDirectory = profileDirectory
        self.displayName = displayName
        self.proposedProfileID = proposedProfileID
        self.targetProfileID = targetProfileID
    }

    public var sourceKey: String { "\(browser.rawValue)/\(profileDirectory)" }

    /// The structured `source` for `create-browser-profile`.
    public var sourceFields: [String: String] {
        ["browser": browser.rawValue, "profile_dir": profileDirectory, "display_name": displayName]
    }
}

/// Result of a finished import.
public struct ImportSummary: Sendable, Equatable {
    public var batches: [ImportBatch]
    /// Profiles that failed, with a short reason (the rest still imported).
    public var failures: [String: String]

    public init(batches: [ImportBatch], failures: [String: String] = [:]) {
        self.batches = batches
        self.failures = failures
    }

    public var counts: ImportCounts { batches.reduce(ImportCounts()) { $0 + $1.counts } }
    public var extensions: [ImportedExtension] {
        var seen = Set<String>()
        return batches.flatMap(\.extensions).filter { seen.insert($0.id).inserted }
    }
    public var openTabs: [ImportedTab] { batches.flatMap(\.openTabs) }
}
