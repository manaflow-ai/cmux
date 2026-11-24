internal import CCmuxCookieSyncFFI
import CmuxNextCompat
public import Foundation
import os

/// Keep cookies in sync (Leo 2026-11-07: "we should be able to, like, just keep it in sync always,
/// right?"): after cookies came over from a Chromium profile, the sites whose cookies change there
/// come over again, while `browser.import.cookieSync` and `browser.import.enabled` are on.
///
/// This is glue only. The Rust sync (cmux-tui/crates/cmux-cookie-sync over the app FFI, one thread)
/// watches each synced profile's `Cookies` database, coalesces its writes, checks it once at start
/// (Chrome ran while cmux was closed), diffs it against the last committed state and reports the
/// changed sites; it never decrypts. This actor hands each report to the importer that already
/// reads, decrypts and writes cookies (``CookieImporter``, filtered to those sites), then commits.
/// Nothing leaves the Mac. ``reconcile()`` starts and stops the Rust sync to match the store;
/// ``setPaused(_:)`` follows the two settings; the app's exit ends the sync's thread. A source
/// whose profile is gone, or whose cookies cannot be read, stops being synced; a refused Keychain
/// key stops its browser's sources and is said once (`stopped`), never asked again in a loop. The
/// Keychain key is read at most once while a sync runs (``OneReadSafeStorage``, zeroed when it
/// stops), and not at all until a site changes.
public actor ImportCookieSync {
    /// Tells the person once that a browser's cookies stopped syncing (its display name).
    public typealias Stopped = @MainActor @Sendable (_ browser: String) -> Void

    private let store: ImportedDataStore
    private let grants: BrowserFolderGrants?
    private let destination: any CookieDestination
    private let keySource: any SafeStorageKeyProviding
    private let stateDirectory: URL
    private let stopped: Stopped
    private let log = Logger(subsystem: "com.cmuxterm.app.next", category: "cookie-sync")
    private var handle: CookieSyncHandle?
    /// Counts the syncs started: a report or an import of an earlier one changes nothing.
    private var generation = 0
    /// Reads the running sync's reports, in order; ends with it.
    private var reader: Task<Void, Never>?
    /// The sources the running sync watches (source key to database), to restart only on a change.
    private var watching: [String: URL] = [:]
    private var keys: OneReadSafeStorage?
    /// Each source's newest change not yet imported. A newer report diffs from the same baseline as
    /// an older one, so only the newest is imported, and nothing commits while one waits.
    private var latest: [String: CookieSyncReport] = [:]
    /// Sources whose changes are being imported now.
    private var importing: Set<String> = []
    /// Browsers whose sync is stopping after a refused key (``stopBrowser(of:)``).
    private var stopping: Set<ImportBrowser> = []
    /// Off (the setting, or browser import off): nothing is watched.
    public private(set) var isPaused = true
    /// What the sync did this launch (diagnostics and the PR's numbers).
    public private(set) var stats = CookieSyncStats()
    /// The sync's debounce and least interval in milliseconds; nil keeps its own (tests shorten them).
    var timing: (debounce: Int, minimumInterval: Int)?

    /// - Parameters:
    ///   - stateDirectory: Where the Rust sync keeps each source's last committed state.
    ///   - keys: The Keychain reader (each session reads through one ``OneReadSafeStorage``).
    public init(store: ImportedDataStore, grants: BrowserFolderGrants?, destination: any CookieDestination,
                keys: any SafeStorageKeyProviding, stateDirectory: URL, stopped: @escaping Stopped) {
        self.store = store
        self.grants = grants
        self.destination = destination
        keySource = keys
        self.stateDirectory = stateDirectory
        self.stopped = stopped
    }

    /// The sources being watched now.
    public var watched: Set<String> { Set(watching.keys) }

    /// No change is importing and no browser's sync is stopping now: what an import or a refused key
    /// leaves (cookies written, the person told) is all there (tests wait on it).
    var isSettled: Bool { importing.isEmpty && stopping.isEmpty }

    /// Shortens the sync's waits (tests); applies from the next start.
    func setTiming(debounce: Int, minimumInterval: Int) { timing = (debounce, minimumInterval) }

    /// On: watches the synced sources; off: stops at once.
    public func setPaused(_ paused: Bool) async {
        guard paused != isPaused else { return }
        isPaused = paused
        await reconcile()
    }

    /// Matches the running sync to the store's synced sources (after an import, a removal or a stop).
    public func reconcile() async {
        guard !isPaused else { return end() }
        let records = await store.cookieSyncedSources()
        guard !isPaused else { return end() }
        var next: [String: URL] = [:]
        for record in records { if let file = record.syncedCookieFile { next[record.sourceKey] = file } }
        guard next != watching else { return }
        end()
        guard !next.isEmpty else { return }
        let scopes = Set(records.map(\.browser)).compactMap { grants?.grantedFolder($0) }
        let config = CookieSyncConfig(stateDirectory: stateDirectory.path, sources: next.map { .init(id: $0.key, database: $0.value.path) },
                                      debounceMilliseconds: timing?.debounce, minimumIntervalMilliseconds: timing?.minimumInterval)
        do {
            try FileManager.checked.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        } catch {
            log.error("cookie sync: no state folder: \(String(describing: type(of: error)), privacy: .public)")
            return
        }
        guard let started = CookieSyncHandle(config: config, scopes: scopes) else {
            log.error("cookie sync: the sync did not start")
            return
        }
        handle = started
        watching = next
        generation += 1
        // task-owner: this actor's `reader`, cancelled by end(); its stream also finishes when the handle goes
        reader = Task { [weak self, reports = started.reports, generation] in
            for await report in reports { await self?.accept(report, of: generation) }
        }
    }

    /// Stops watching (the app quits).
    public func stop() { end() }

    private func end() {
        // An import already running sees another generation and writes nothing more (`isCurrent`).
        generation += 1
        reader?.cancel()
        reader = nil
        handle = nil
        watching = [:]
        latest = [:]
        keys = nil
    }

    func accept(_ report: CookieSyncReport, of sync: Int) {
        guard sync == generation, handle != nil, watching[report.source] != nil else { return }
        stats.note(report)
        switch report.kind {
        case "changed":
            log.info("cookie sync \(report.source, privacy: .public): \(report.changed.count) sites changed, \(report.removed.count) removed (\(report.reason ?? "", privacy: .public)), scan \(report.scanMs ?? 0, format: .fixed(precision: 1)) ms, cpu \(report.cpuMs ?? 0, format: .fixed(precision: 1)) ms, \(report.rows ?? 0) rows")
            latest[report.source] = report
            guard !importing.contains(report.source) else { return }
            importing.insert(report.source)
            // task-owner: drains this source's reports, then ends (importing)
            Task { await drain(report.source, through: sync) }
        case "gone", "failed":
            log.info("cookie sync \(report.source, privacy: .public) stops: \(report.kind, privacy: .public) \(report.reason ?? "", privacy: .public)")
            // task-owner: one store write and a restart without the source
            Task {
                try? await store.stopCookieSync(sourceKey: report.source)
                await reconcile()
            }
        default:
            break
        }
    }

    /// Imports the source's newest change until none waits, then commits it as the baseline. The
    /// cookies a site dropped stay in cmux: a sign-out in the browser does not sign cmux out.
    private func drain(_ source: String, through sync: Int) async {
        defer { importing.remove(source) }
        while let report = latest.removeValue(forKey: source) {
            if !report.changed.isEmpty {
                guard isCurrent(sync), await bringOver(report, of: sync) else { return }
            }
            // A newer report came while importing: it is imported before anything commits. A paused or
            // restarted sync is gone, and the next one reports again.
            if latest[source] == nil, sync == generation, let reported = report.generation { handle?.commit(source, generation: reported) }
        }
    }

    /// One report's sites into the source's profile; false when it could not be imported.
    private func bringOver(_ report: CookieSyncReport, of sync: Int) async -> Bool {
        guard let record = await store.cookieSyncedSources().first(where: { $0.sourceKey == report.source }),
              let file = record.syncedCookieFile, isCurrent(sync) else { return false }
        let keys = keys ?? OneReadSafeStorage(keySource)
        self.keys = keys
        let started = ContinuousClock.now
        do {
            let writes = CurrentSyncOnly(destination: destination) { [weak self] in await self?.isCurrent(sync) ?? false }
            let result = try await CookieImporter(destination: writes, keys: keys)
                .run(Self.profile(record, file: file), into: record.targetProfileID, filter: CookieDomainFilter(report.changed))
            let milliseconds = stats.imported(result.written, in: ContinuousClock.now - started)
            log.info("cookie sync \(report.source, privacy: .public): \(result.written) cookies of \(report.changed.count) sites in \(milliseconds, format: .fixed(precision: 1)) ms")
            return true
        } catch let error as CookieImportError {
            switch error {
            case .keychainDenied, .keyNotFound, .refused:
                await stopBrowser(of: record)
            default:
                log.error("cookie sync \(report.source, privacy: .public): import failed: \(String(describing: error), privacy: .public)")
            }
        } catch {
            log.error("cookie sync \(report.source, privacy: .public): import failed: \(String(describing: type(of: error)), privacy: .public)")
        }
        return false
    }

    /// Whether `sync` is still the running sync: off, quit or restarted, it is not.
    private func isCurrent(_ sync: Int) -> Bool { sync == generation && !isPaused && handle != nil }

    /// Every synced source of `source`'s browser stops, and the person hears it once: another profile
    /// of that browser refused while this one stops, or after it stopped, says nothing more.
    private func stopBrowser(of source: ImportSourceRecord) async {
        let browser = source.browser
        guard stopping.insert(browser).inserted else { return }
        defer { stopping.remove(browser) }
        guard await store.cookieSyncedSources().contains(where: { $0.sourceKey == source.sourceKey }) else { return }
        for record in await store.cookieSyncedSources() where record.browser == browser {
            try? await store.stopCookieSync(sourceKey: record.sourceKey)
        }
        keys = nil
        await reconcile()
        await stopped(browser.displayName)
    }

    /// The source profile the importer reads: the folder of its `Cookies` (or `Network/Cookies`).
    static func profile(_ record: ImportSourceRecord, file: URL) -> BrowserSourceProfile {
        var folder = file.deletingLastPathComponent()
        if folder.lastPathComponent == "Network" { folder.deleteLastPathComponent() }
        return BrowserSourceProfile(browser: record.browser, directoryName: record.profileDirectory,
                                    displayName: record.profileName ?? record.displayName, path: folder, availability: [:])
    }
}

/// What the sync did this launch: scans, changes and imports, with their cost.
public struct CookieSyncStats: Sendable, Equatable {
    public var scans = 0
    public var changes = 0
    public var cookiesWritten = 0
    public var scanMilliseconds: Double = 0
    public var scanCPUMilliseconds: Double = 0
    public var importMilliseconds: Double = 0

    mutating func note(_ report: CookieSyncReport) {
        guard report.kind == "changed" || report.kind == "scanned" else { return }
        scans += 1
        if report.kind == "changed" { changes += 1 }
        scanMilliseconds += report.scanMs ?? 0
        scanCPUMilliseconds += report.cpuMs ?? 0
    }

    /// - Returns: The import's milliseconds.
    @discardableResult
    mutating func imported(_ written: Int, in duration: Duration) -> Double {
        let parts = duration.components
        let milliseconds = Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
        cookiesWritten += written
        importMilliseconds += milliseconds
        return milliseconds
    }
}

/// The Rust sync's config (`cmux_cookie_sync_new`).
struct CookieSyncConfig: Encodable {
    struct Source: Encodable {
        let id: String
        let database: String
    }

    let stateDirectory: String
    let sources: [Source]
    /// Nil: the sync's own (2 s after the last write, at most one scan per source each 30 s).
    var debounceMilliseconds: Int?
    var minimumIntervalMilliseconds: Int?

    enum CodingKeys: String, CodingKey {
        case stateDirectory = "state_dir"
        case sources
        case debounceMilliseconds = "debounce_ms"
        case minimumIntervalMilliseconds = "min_interval_ms"
    }
}

/// One report of the Rust sync (cmux_cookie_sync.h).
struct CookieSyncReport: Decodable, Sendable, Equatable {
    var kind: String
    var source: String
    /// A `changed` report's number, which its commit names (a later one covers it).
    var generation: UInt64?
    var changed: [String] = []
    var removed: [String] = []
    var rows: Int?
    var hosts: Int?
    var scanMs: Double?
    var cpuMs: Double?
    var reason: String?

    enum CodingKeys: String, CodingKey {
        case kind, source, generation, changed, removed, rows, hosts, reason
        case scanMs = "scan_ms"
        case cpuMs = "cpu_ms"
    }

    init(kind: String, source: String, generation: UInt64? = nil, changed: [String] = [], removed: [String] = [], reason: String? = nil) {
        self.kind = kind
        self.source = source
        self.generation = generation
        self.changed = changed
        self.removed = removed
        self.reason = reason
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
        generation = try container.decodeIfPresent(UInt64.self, forKey: .generation)
        changed = try container.decodeIfPresent([String].self, forKey: .changed) ?? []
        removed = try container.decodeIfPresent([String].self, forKey: .removed) ?? []
        rows = try container.decodeIfPresent(Int.self, forKey: .rows)
        hosts = try container.decodeIfPresent(Int.self, forKey: .hosts)
        scanMs = try container.decodeIfPresent(Double.self, forKey: .scanMs)
        cpuMs = try container.decodeIfPresent(Double.self, forKey: .cpuMs)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
    }
}

/// Writes cookies only while the sync that read them still runs: turned off mid-import (or quit, or
/// restarted), the import writes nothing more, even after a Keychain prompt it was waiting on.
private struct CurrentSyncOnly: CookieDestination {
    let destination: any CookieDestination
    let isCurrent: @Sendable () async -> Bool

    func setCookies(_ cookies: [ImportedCookie], profileID: String) async throws -> CookieWriteResult {
        guard await isCurrent() else { return CookieWriteResult(written: 0, rejected: 0) }
        return try await destination.setCookies(cookies, profileID: profileID)
    }
}

/// One running Rust sync, owned by ``ImportCookieSync``: started on a config, stopped (its thread
/// joined) when released. Holds the browsers' folder grants in scope while it watches.
final class CookieSyncHandle {
    private let pointer: OpaquePointer
    private let inbox: Unmanaged<Inbox>
    private let scopes: [URL]

    /// Hands the sync's reports, from its thread, to `reports` in order.
    final class Inbox: Sendable {
        let sink: AsyncStream<CookieSyncReport>.Continuation
        init(_ sink: AsyncStream<CookieSyncReport>.Continuation) { self.sink = sink }
    }

    /// The sync's reports, in order; finishes when the sync stops. A slow reader keeps the newest 64.
    let reports: AsyncStream<CookieSyncReport>

    init?(config: CookieSyncConfig, scopes: [URL]) {
        guard let json = try? JSONEncoder().encode(config) else { return nil }
        let (reports, sink) = AsyncStream.makeStream(of: CookieSyncReport.self, bufferingPolicy: .bufferingNewest(64))
        let scoped = scopes.filter { $0.startAccessingSecurityScopedResource() }
        let inbox = Unmanaged.passRetained(Inbox(sink))
        let made = json.withUnsafeBytes { bytes in
            cmux_cookie_sync_new(bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count, { context, report, length in
                guard let context, let report,
                      let decoded = try? JSONDecoder().decode(CookieSyncReport.self, from: Data(bytes: report, count: length)) else { return }
                Unmanaged<Inbox>.fromOpaque(context).takeUnretainedValue().sink.yield(decoded)
            }, inbox.toOpaque())
        }
        guard let made else {
            inbox.release()
            sink.finish()
            scoped.forEach { $0.stopAccessingSecurityScopedResource() }
            return nil
        }
        pointer = made
        self.inbox = inbox
        self.scopes = scoped
        self.reports = reports
    }

    deinit {
        // Joins the sync's thread: no callback runs after this, so the inbox can go.
        cmux_cookie_sync_free(pointer)
        inbox.takeUnretainedValue().sink.finish()
        inbox.release()
        scopes.forEach { $0.stopAccessingSecurityScopedResource() }
    }

    /// The change `source` reported as `generation` was imported: it becomes the source's baseline.
    @discardableResult
    func commit(_ source: String, generation: UInt64) -> Bool {
        let id = Array(source.utf8)
        return id.withUnsafeBufferPointer { cmux_cookie_sync_commit(pointer, $0.baseAddress, $0.count, generation) }
    }
}
