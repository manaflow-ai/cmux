public import Foundation

/// Runs an ``ImportPlan``: for each source profile, reads each picked kind,
/// reports progress, then hands the batch to the destination. Runs off the
/// main thread; cancel the calling task to stop between reads (SQLite reads
/// also check every 256 rows). A profile that fails is reported and the
/// rest continue.
public actor BrowserImporter {
    private let provisioning: any BrowserProfileProvisioning
    private let store: ImportedDataStore?
    private let cookies: CookieImporter?
    private let passwords: PasswordImporter?
    private let reader: BrowserDataReader

    /// `reader` reads bookmarks, history, tabs, search engines and extensions (the daemon's
    /// `browser_import.read`). `cookies` or `passwords` nil: that kind is skipped (no store to write to).
    public init(reader: BrowserDataReader, provisioning: any BrowserProfileProvisioning = DefaultProfileOnly(),
                store: ImportedDataStore? = nil, cookies: CookieImporter? = nil, passwords: PasswordImporter? = nil) {
        self.reader = reader
        self.provisioning = provisioning
        self.store = store
        self.cookies = cookies
        self.passwords = passwords
    }

    public func run(
        _ plan: ImportPlan,
        into destination: any ImportDestination,
        progress: @escaping @Sendable (ImportProgress) -> Void
    ) async throws -> ImportSummary {
        var batches: [ImportBatch] = []
        var failures: [String: String] = [:]
        var running = ImportCounts()
        let steps = max(1, plan.items.reduce(0) { $0 + $1.kinds.count + 1 })
        var done = 0
        for (index, item) in plan.items.enumerated() {
            try Task.checkCancellation()
            let report: @Sendable (ImportDataKind?, ImportCounts, Int) -> Void = { kind, counts, step in
                progress(ImportProgress(profileIndex: index, profileCount: plan.items.count, profile: item.profile,
                                        kind: kind, fraction: Double(step) / Double(steps), counts: counts))
            }
            do {
                var batch = ImportBatch(source: try await record(for: item.profile, target: plan.mergeTarget ?? item.target), kinds: item.kinds)
                if plan.keepsHistoryInSync, item.kinds.contains(.history) { batch.source.syncedHistoryFile = item.profile.historyFile }
                for kind in ImportDataKind.allCases where item.kinds.contains(kind) {
                    report(kind, running + batch.counts, done)
                    try Task.checkCancellation()
                    if kind == .cookies {
                        try await importCookies(item.profile, into: &batch)
                    } else if kind == .passwords {
                        try await importPasswords(item.profile, into: &batch)
                    } else {
                        try await read(kind, from: item.profile, historyLimit: plan.historyLimit, into: &batch)
                    }
                    done += 1
                }
                // Its cookie file, once cookies came over from a Chromium profile (the one format the sync reads):
                // `browser.import.cookieSync` decides whether it is watched (``ImportCookieSync``).
                if (batch.cookies?.written ?? 0) > 0, item.profile.browser.family == .chromium {
                    batch.source.syncedCookieFile = BrowserSourceDetector.chromiumCookieFile(item.profile.path)
                }
                report(nil, running + batch.counts, done)
                try Task.checkCancellation()
                try await destination.commit(batch)
                done += 1
                running = running + batch.counts
                batches.append(batch)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures[item.profile.id] = String(describing: error)
                done += item.kinds.count + 1
            }
        }
        progress(ImportProgress(profileIndex: plan.items.count, profileCount: plan.items.count,
                                profile: plan.items.last?.profile ?? Self.placeholder, kind: nil, fraction: 1, counts: running))
        return ImportSummary(batches: batches, failures: failures)
    }

    /// Cookies fail on their own (a denied Keychain prompt must not lose the
    /// profile's bookmarks); the reason is kept in the batch.
    private func importCookies(_ profile: BrowserSourceProfile, into batch: inout ImportBatch) async throws {
        guard let cookies else { return }
        do {
            batch.cookies = try await cookies.run(profile, into: batch.source.targetProfileID)
        } catch let error as CookieImportError {
            batch.cookieError = error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            batch.cookieError = .malformed(String(describing: type(of: error)))
        }
    }

    /// Passwords fail on their own too, for the same reason.
    private func importPasswords(_ profile: BrowserSourceProfile, into batch: inout ImportBatch) async throws {
        guard let passwords else { return }
        do {
            batch.passwords = try await passwords.run(profile, intoProfile: batch.source.targetProfileID)
        } catch let error as PasswordImporter.Failure {
            batch.passwordError = error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A Login Data file that would not open: counted, never described (the message could hold a path or a row).
            batch.passwordError = .unreadable
        }
    }

    /// The mapping for a source: its proposed profile id (reused from an
    /// earlier import), and the profile the data goes to now: `target`, or
    /// the source's own profile, made with its name, color and picture.
    private func record(for profile: BrowserSourceProfile, target: String?) async throws -> ImportSourceRecord {
        let proposed = await store?.proposedProfileID(for: profile.id) ?? UUID().uuidString.lowercased()
        let single = profile.browser.family == .safari || profile.browser.family.isPrivateStore || profile.directoryName.isEmpty
        let name = single ? profile.browser.displayName : "\(profile.browser.displayName) · \(profile.displayName)"
        var record = ImportSourceRecord(browser: profile.browser, profileDirectory: profile.directoryName, displayName: name,
                                        proposedProfileID: proposed, targetProfileID: "default", profileName: single ? nil : profile.displayName)
        if let target {
            record.targetProfileID = target
        } else {
            record.targetProfileID = try await provisioning.createProfile(id: proposed, name: name, look: SourceProfileLook(profile),
                                                                          source: record.sourceFields)
        }
        return record
    }

    private func read(_ kind: ImportDataKind, from profile: BrowserSourceProfile, historyLimit: Int, into batch: inout ImportBatch) async throws {
        #if CMUX_NO_BROWSER_DATA_IMPORT || CMUX_NO_HISTORY_IMPORT
        // The cx-f58x notary test builds read no other browser's history,
        // tabs, extensions or bookmarks (CMUX_NO_HISTORY_IMPORT is the
        // history-only notary bisect build).
        return
        #else
        switch kind {
        case .bookmarks: batch.bookmarks = try await reader.bookmarks(profile)
        case .history: if let file = profile.historyFile { batch.history = try await reader.history(profile.browser.family, file: file, limit: historyLimit) }
        case .openTabs: batch.openTabs = try await reader.openTabs(profile)
        case .searchEngines: batch.searchEngine = try await reader.searchEngine(profile)
        case .extensions: batch.extensions = try await reader.extensions(profile)
        case .cookies, .passwords: return
        }
        #endif
    }

    private static let placeholder = BrowserSourceProfile(browser: .chrome, directoryName: "", displayName: "",
                                                          path: URL(fileURLWithPath: "/"), availability: [:])
}
