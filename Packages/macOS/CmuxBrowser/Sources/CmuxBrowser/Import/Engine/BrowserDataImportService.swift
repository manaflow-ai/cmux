import Foundation

/// Reads cookies and browsing history out of an installed browser's on-disk
/// SQLite databases and writes them into a cmux destination profile.
///
/// This is the self-contained import engine behind the browser-data import flow
/// (settings UI, `browser.import.*` socket commands, and the import wizard). It
/// performs the off-main SQLite reads, Chromium cookie decryption, deduping, and
/// date conversion itself; the two destination sinks (the profile's cookie store
/// and history store) are injected through ``BrowserImportProfileDataWriting`` so
/// the engine never depends on the app's `BrowserProfileStore`. Localized warning
/// text is injected through ``BrowserImportWarningStrings`` because
/// `String(localized:)` must resolve in the app bundle.
///
/// Replaces the former app-target `BrowserDataImporter` caseless namespace enum
/// with a real instance type holding its constructor-injected sink and strings.
/// Every read query, decryption step, dedupe key, date conversion, and warning is
/// byte-faithful to that original; only the destination writes and localized
/// strings moved behind the seams.
///
/// ## Isolation
///
/// `Sendable`, NOT `@MainActor`. The import runs off-main (file copy, SQLite,
/// crypto) and hops to the `@MainActor` sink only to resolve the cookie store, set
/// each cookie, and merge history, exactly as the original hopped through
/// `MainActor.run` / `BrowserProfileStore.shared`.
public struct BrowserDataImportService: Sendable {
    struct CookieImportResult {
        var importedCount: Int = 0
        var skippedCount: Int = 0
        var warnings: [String] = []
    }

    struct HistoryImportResult {
        var importedCount: Int = 0
        var warnings: [String] = []
    }

    /// The destination cookie/history sink, resolved against the app's profile store.
    let sink: any BrowserImportProfileDataWriting
    /// App-bundle-localized warning templates.
    let strings: BrowserImportWarningStrings

    /// Creates an import engine.
    /// - Parameters:
    ///   - sink: The destination cookie/history sink (the app's profile store).
    ///   - strings: App-resolved localized warning templates.
    public init(sink: any BrowserImportProfileDataWriting, strings: BrowserImportWarningStrings) {
        self.sink = sink
        self.strings = strings
    }

    /// Parses a raw domain-filter string into normalized host suffixes.
    ///
    /// Splits on whitespace/newlines/`,`/`;`, lowercases, strips a leading `*.`
    /// and any leading dots, drops empties, and dedupes preserving order. Pure;
    /// callable without constructing the engine.
    /// - Parameter raw: The raw domain-filter text.
    /// - Returns: The normalized, deduplicated domain filters.
    public static func parseDomainFilters(_ raw: String) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;"))
        for token in raw.components(separatedBy: separators) {
            var value = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if value.hasPrefix("*.") {
                value.removeFirst(2)
            }
            while value.hasPrefix(".") {
                value.removeFirst()
            }
            guard !value.isEmpty else { continue }
            guard seen.insert(value).inserted else { continue }
            result.append(value)
        }
        return result
    }

    /// Imports the configured data tiers for a browser against a realized plan.
    ///
    /// Runs every plan entry, deduping warnings, and appends the "additional data
    /// unavailable" note when the scope is `.everything`.
    /// - Parameters:
    ///   - browser: The source browser candidate.
    ///   - plan: The realized destination plan.
    ///   - scope: Which data tiers to import.
    ///   - domainFilters: Normalized host filters; empty means no filtering.
    /// - Returns: The aggregate import outcome.
    public func importData(
        from browser: InstalledBrowserCandidate,
        plan: RealizedBrowserImportExecutionPlan,
        scope: BrowserImportScope,
        domainFilters: [String]
    ) async -> BrowserImportOutcome {
        var outcomeEntries: [BrowserImportOutcomeEntry] = []
        var warnings: [String] = []
        var seenWarnings = Set<String>()

        for entry in plan.entries {
            let outcomeEntry = await importEntry(
                from: browser,
                sourceProfiles: entry.sourceProfiles,
                destinationProfileID: entry.destinationProfileID,
                destinationProfileName: entry.destinationProfileName,
                scope: scope,
                domainFilters: domainFilters
            )
            outcomeEntries.append(outcomeEntry)
            for warning in outcomeEntry.warnings where seenWarnings.insert(warning).inserted {
                warnings.append(warning)
            }
        }

        if scope == .everything {
            let unavailableWarning = strings.additionalDataUnavailable
            if seenWarnings.insert(unavailableWarning).inserted {
                warnings.append(unavailableWarning)
            }
        }

        return BrowserImportOutcome(
            browserName: browser.displayName,
            scope: scope,
            domainFilters: domainFilters,
            createdDestinationProfileNames: plan.createdProfiles.map(\.displayName),
            entries: outcomeEntries,
            warnings: warnings
        )
    }

    private func importEntry(
        from browser: InstalledBrowserCandidate,
        sourceProfiles: [InstalledBrowserProfile],
        destinationProfileID: UUID,
        destinationProfileName: String,
        scope: BrowserImportScope,
        domainFilters: [String]
    ) async -> BrowserImportOutcomeEntry {
        let resolvedSourceProfiles = sourceProfiles.isEmpty ? browser.profiles : sourceProfiles
        var cookieResult = CookieImportResult()
        if scope.includesCookies {
            cookieResult = await importCookies(
                from: browser,
                sourceProfiles: resolvedSourceProfiles,
                destinationProfileID: destinationProfileID,
                domainFilters: domainFilters
            )
        }

        var historyResult = HistoryImportResult()
        if scope.includesHistory {
            historyResult = await importHistory(
                from: browser,
                sourceProfiles: resolvedSourceProfiles,
                destinationProfileID: destinationProfileID,
                domainFilters: domainFilters
            )
        }

        var warnings = cookieResult.warnings
        warnings.append(contentsOf: historyResult.warnings)
        return BrowserImportOutcomeEntry(
            sourceProfileNames: resolvedSourceProfiles.map(\.displayName),
            destinationProfileName: destinationProfileName,
            importedCookies: cookieResult.importedCount,
            skippedCookies: cookieResult.skippedCount,
            importedHistoryEntries: historyResult.importedCount,
            warnings: warnings
        )
    }
}
