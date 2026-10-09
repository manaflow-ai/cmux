import Foundation

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

    /// `cookies` or `passwords` nil: that kind is skipped (no store to write to).
    public init(provisioning: any BrowserProfileProvisioning = DefaultProfileOnly(), store: ImportedDataStore? = nil,
                cookies: CookieImporter? = nil, passwords: PasswordImporter? = nil) {
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
                var batch = ImportBatch(source: try await record(for: item.profile, mergeTarget: plan.mergeTarget), kinds: item.kinds)
                for kind in ImportDataKind.allCases where item.kinds.contains(kind) {
                    report(kind, running + batch.counts, done)
                    try Task.checkCancellation()
                    if kind == .cookies {
                        try await importCookies(item.profile, into: &batch)
                    } else if kind == .passwords {
                        try await importPasswords(item.profile, into: &batch)
                    } else {
                        try Self.read(kind, from: item.profile, historyLimit: plan.historyLimit, into: &batch)
                    }
                    done += 1
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
    /// earlier import), and the profile the data goes to now.
    private func record(for profile: BrowserSourceProfile, mergeTarget: String?) async throws -> ImportSourceRecord {
        let proposed = await store?.proposedProfileID(for: profile.id) ?? UUID().uuidString.lowercased()
        let single = profile.browser.family == .safari || profile.browser.family.isPrivateStore || profile.directoryName.isEmpty
        let name = single ? profile.browser.displayName : "\(profile.browser.displayName) · \(profile.displayName)"
        var record = ImportSourceRecord(browser: profile.browser, profileDirectory: profile.directoryName, displayName: name,
                                        proposedProfileID: proposed, targetProfileID: "default", profileName: single ? nil : profile.displayName)
        if let mergeTarget {
            record.targetProfileID = mergeTarget
        } else {
            record.targetProfileID = try await provisioning.createProfile(id: proposed, name: name, color: nil, source: record.sourceFields)
        }
        return record
    }

    static func read(_ kind: ImportDataKind, from profile: BrowserSourceProfile, historyLimit: Int, into batch: inout ImportBatch) throws {
        #if CMUX_NO_BROWSER_DATA_IMPORT
        // The cx-f58x notary test build reads no other browser's history,
        // tabs, extensions or bookmarks.
        return
        #else
        let path = profile.path
        if kind == .bookmarks {
            batch.bookmarks = try readBookmarks(profile)
            return
        }
        switch (profile.browser.family, kind) {
        case (.chromium, .history):
            batch.history = try ChromiumHistoryReader().read(path.appending(path: "History"), limit: historyLimit)
        case (.chromium, .openTabs):
            if let file = ChromiumSessionReader().sessionFile(profile: path) { batch.openTabs = ChromiumSessionReader().parse(try Data(contentsOf: file)) }
        case (.chromium, .extensions):
            batch.extensions = ChromiumExtensionsReader().read(profile: path)
        case (.firefox, .history):
            batch.history = try FirefoxPlacesReader().readHistory(path.appending(path: "places.sqlite"), limit: historyLimit)
        case (.firefox, .openTabs):
            if let file = FirefoxSessionReader().sessionFile(in: path) { batch.openTabs = FirefoxSessionReader().parse(try Data(contentsOf: file)) }
        case (.safari, .history):
            batch.history = try SafariHistoryReader().read(path.appending(path: "History.db"), limit: historyLimit)
        default:
            return
        }
        #endif
    }

    /// One profile's bookmarks, read with the reader its registry row names
    /// (engine family, not browser). Sources the reader cannot open throw;
    /// private stores return nothing (their HTML export is the path).
    public static func readBookmarks(_ profile: BrowserSourceProfile) throws -> [ImportedBookmark] {
        #if CMUX_NO_BROWSER_DATA_IMPORT
        return []
        #else
        let files = profile.browser.source?.files
        func file(_ fallback: String) -> URL { profile.bookmarksFile ?? profile.path.appending(path: files?.bookmarks ?? fallback) }
        switch profile.browser.bookmarksFormat {
        case .chromiumJSON:
            return try ChromiumBookmarksParser().parse(Data(contentsOf: file("Bookmarks")))
        case .firefoxPlaces:
            return try FirefoxPlacesReader().readBookmarks(file("places.sqlite"))
        case .safariPlist:
            return try SafariBookmarksParser().parse(Data(contentsOf: file("Bookmarks.plist")))
        case .arcSidebar:
            // No sidebar file: Arc's Chromium `Bookmarks` file is the fallback.
            guard let sidebar = profile.bookmarksFile else {
                return try ChromiumBookmarksParser().parse(Data(contentsOf: profile.path.appending(path: files?.bookmarks ?? "Bookmarks")))
            }
            return try ArcSidebarReader().parse(Data(contentsOf: sidebar), profileDirectory: profile.directoryName)
        case .htmlExport, .noStore:
            return []
        }
        #endif
    }

    private static let placeholder = BrowserSourceProfile(browser: .chrome, directoryName: "", displayName: "",
                                                          path: URL(fileURLWithPath: "/"), availability: [:])
}
