@testable import CmuxNextBrowserImport
import Foundation
import os
import SQLite3
import Testing

/// Keep cookies in sync (Leo 2026-11-07: "we should be able to, like, just keep it in sync always"):
/// the Rust sync watches a synced Chrome profile's `Cookies`, and only the sites whose cookies
/// changed come over again; a refused Keychain key stops that browser's sync and says so once.
@Suite(.serialized) struct ImportCookieSyncTests {
    /// The cookies written, per profile.
    private actor Jar: CookieDestination {
        private(set) var written: [String: [ImportedCookie]] = [:]
        func setCookies(_ cookies: [ImportedCookie], profileID: String) async throws -> CookieWriteResult {
            written[profileID, default: []] += cookies
            return CookieWriteResult(written: cookies.count, rejected: 0)
        }

        var hosts: Set<String> { Set(written.values.flatMap { $0.map(\.domain) }) }
    }

    /// A Keychain that refuses, counting its prompts.
    private final class Refusing: SafeStorageKeyProviding {
        private let count = OSAllocatedUnfairLock(initialState: 0)
        var asked: Int { count.withLock { $0 } }
        func password(service: String) throws(CookieImportError) -> SecretBytes {
            count.withLock { $0 += 1 }
            throw .keychainDenied(service: service)
        }
    }

    /// A Keychain that answers after half a second (a prompt the person is reading), counting its prompts.
    private final class Slow: SafeStorageKeyProviding {
        private let base: FixtureSafeStorage
        private let count = OSAllocatedUnfairLock(initialState: 0)
        var asked: Int { count.withLock { $0 } }
        init(_ base: FixtureSafeStorage) { self.base = base }
        func password(service: String) throws(CookieImportError) -> SecretBytes {
            count.withLock { $0 += 1 }
            Thread.sleep(forTimeInterval: 0.5)
            return try base.password(service: service)
        }
    }

    /// What the sync told the person.
    private final class Said: Sendable {
        private let said = OSAllocatedUnfairLock<[String]>(initialState: [])
        var lines: [String] { said.withLock { $0 } }
        func add(_ line: String) { said.withLock { $0.append(line) } }
    }

    private static func until(_ condition: () async -> Bool, within timeout: Duration = .seconds(15)) async {
        let deadline = ContinuousClock.now + timeout
        while await !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(25)) }
    }

    /// A Chromium `Cookies` database (meta version 24) holding one plaintext cookie per host, `value` unless `values` names one.
    private static func cookies(_ file: URL, hosts: [String], value: String = "v1", values: [String: String] = [:]) throws {
        var db: OpaquePointer?
        guard sqlite3_open(file.path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        var sql = """
            CREATE TABLE IF NOT EXISTS meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
            INSERT OR REPLACE INTO meta VALUES('version', '24');
            CREATE TABLE IF NOT EXISTS cookies(creation_utc INTEGER NOT NULL, host_key TEXT NOT NULL, top_frame_site_key TEXT NOT NULL,
              name TEXT NOT NULL, value TEXT NOT NULL, encrypted_value BLOB NOT NULL, path TEXT NOT NULL,
              expires_utc INTEGER NOT NULL, is_secure INTEGER NOT NULL, is_httponly INTEGER NOT NULL,
              last_access_utc INTEGER NOT NULL, has_expires INTEGER NOT NULL, is_persistent INTEGER NOT NULL,
              priority INTEGER NOT NULL, samesite INTEGER NOT NULL, source_scheme INTEGER NOT NULL,
              source_port INTEGER NOT NULL, last_update_utc INTEGER NOT NULL, source_type INTEGER NOT NULL,
              has_cross_site_ancestor INTEGER NOT NULL);
            DELETE FROM cookies;
            """
        for (index, host) in hosts.enumerated() {
            let created = 13_400_000_000_000_000 + index
            sql += "INSERT INTO cookies VALUES(\(created), '\(host)', '', 'sid', '\(values[host] ?? value)', x'', '/', 14000000000000000, 1, 1, \(created), 1, 1, 1, 1, 2, 443, \(created), 0, 0);"
        }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }

    private struct Fixture {
        let root: URL
        let file: URL
        let store: ImportedDataStore
        let record: ImportSourceRecord
    }

    private static func fixture(hosts: [String]) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "cookie-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
        let profile = root.appending(path: "Chrome/Default", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: profile.appending(path: "Network"), withIntermediateDirectories: true)
        let file = profile.appending(path: "Network/Cookies")
        try cookies(file, hosts: hosts)
        let store = ImportedDataStore(directory: root.appending(path: "store", directoryHint: .isDirectory))
        var record = ImportSourceRecord(browser: .chrome, profileDirectory: "Default", displayName: "Google Chrome",
                                        proposedProfileID: "p1", targetProfileID: "p1")
        record.syncedCookieFile = file
        try await store.save(ImportBatch(source: record, kinds: [.cookies]))
        return Fixture(root: root, file: file, store: store, record: record)
    }

    @Test func onlyTheSitesThatChangedComeOverAgain() async throws {
        let fixture = try await Self.fixture(hosts: [".one.example", ".two.example"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let jar = Jar()
        let said = Said()
        let sync = ImportCookieSync(store: fixture.store, grants: nil, destination: jar,
                                    keys: FixtureSafeStorage(passwords: ["Chrome Safe Storage": "fixture"]),
                                    stateDirectory: fixture.root.appending(path: "state")) { said.add($0) }
        await sync.setTiming(debounce: 100, minimumInterval: 0)
        // Paused until the settings say it runs.
        await sync.reconcile()
        #expect(await sync.watched.isEmpty)
        await sync.setPaused(false)
        #expect(await sync.watched == [fixture.record.sourceKey])
        // The first check takes the current cookies as the baseline: nothing is imported again.
        await Self.until { await sync.stats.scans >= 1 }
        #expect(await jar.hosts.isEmpty)

        // Chrome signs in to a third site and refreshes the second; the first is as it was.
        try Self.cookies(fixture.file, hosts: [".one.example", ".two.example", ".three.example"], values: [".two.example": "v2"])
        await Self.until { await jar.hosts.count >= 2 }
        #expect(await jar.hosts == [".two.example", ".three.example"])
        #expect(await jar.written.keys.sorted() == ["p1"])
        #expect(await sync.stats.changes >= 1)
        #expect(said.lines.isEmpty)

        // Off: the watch stops at once.
        await sync.setPaused(true)
        #expect(await sync.watched.isEmpty)
    }

    @Test func aChangeWhileCmuxWasClosedComesOverAtLaunch() async throws {
        let fixture = try await Self.fixture(hosts: [".one.example"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let state = fixture.root.appending(path: "state")
        let keys = FixtureSafeStorage(passwords: ["Chrome Safe Storage": "fixture"])
        let first = ImportCookieSync(store: fixture.store, grants: nil, destination: Jar(), keys: keys, stateDirectory: state) { _ in }
        await first.setPaused(false)
        await Self.until { await first.stats.scans >= 1 }
        await first.stop()

        try Self.cookies(fixture.file, hosts: [".one.example", ".new.example"])
        let jar = Jar()
        let next = ImportCookieSync(store: fixture.store, grants: nil, destination: jar, keys: keys, stateDirectory: state) { _ in }
        await next.setPaused(false)
        await Self.until { await !jar.hosts.isEmpty }
        #expect(await jar.hosts == [".new.example"])
        await next.stop()
    }

    @Test func aRefusedKeyStopsTheBrowsersSyncAndSaysSoOnce() async throws {
        let fixture = try await Self.fixture(hosts: [".one.example"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let keys = Refusing()
        let said = Said()
        let sync = ImportCookieSync(store: fixture.store, grants: nil, destination: Jar(), keys: keys,
                                    stateDirectory: fixture.root.appending(path: "state")) { said.add($0) }
        await sync.setTiming(debounce: 100, minimumInterval: 0)
        await sync.setPaused(false)
        await Self.until { await sync.stats.scans >= 1 }
        try Self.cookies(fixture.file, hosts: [".one.example", ".two.example"])
        await Self.until { !said.lines.isEmpty }
        #expect(said.lines == [ImportBrowser.chrome.displayName])
        #expect(await fixture.store.cookieSyncedSources().isEmpty)
        #expect(await sync.watched.isEmpty)
        // Another write asks the Keychain nothing more.
        try Self.cookies(fixture.file, hosts: [".one.example", ".two.example", ".three.example"])
        try await Task.sleep(for: .milliseconds(500))
        #expect(keys.asked == 1)
        #expect(said.lines.count == 1)
    }

    /// Two synced profiles of one browser refused at once: the person still hears it once.
    @Test func twoRefusedProfilesOfOneBrowserSayItOnce() async throws {
        let fixture = try await Self.fixture(hosts: [".one.example"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let work = fixture.root.appending(path: "Chrome/Profile 1", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work.appending(path: "Network"), withIntermediateDirectories: true)
        let workFile = work.appending(path: "Network/Cookies")
        try Self.cookies(workFile, hosts: [".one.example"])
        var second = ImportSourceRecord(browser: .chrome, profileDirectory: "Profile 1", displayName: "Google Chrome",
                                        proposedProfileID: "p2", targetProfileID: "p2")
        second.syncedCookieFile = workFile
        try await fixture.store.save(ImportBatch(source: second, kinds: [.cookies]))
        let said = Said()
        let sync = ImportCookieSync(store: fixture.store, grants: nil, destination: Jar(), keys: Refusing(),
                                    stateDirectory: fixture.root.appending(path: "state")) { said.add($0) }
        await sync.setTiming(debounce: 100, minimumInterval: 0)
        await sync.setPaused(false)
        await Self.until { await sync.stats.scans >= 2 }
        try Self.cookies(fixture.file, hosts: [".one.example", ".two.example"])
        try Self.cookies(workFile, hosts: [".one.example", ".two.example"])
        await Self.until { await fixture.store.cookieSyncedSources().isEmpty }
        try await Task.sleep(for: .milliseconds(500))
        #expect(said.lines == [ImportBrowser.chrome.displayName])
        #expect(await sync.watched.isEmpty)
    }

    /// Turned off while a change is importing (the Keychain prompt still up): nothing is written.
    @Test func turningItOffMidImportWritesNothing() async throws {
        let fixture = try await Self.fixture(hosts: [".one.example"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let jar = Jar()
        let keys = Slow(FixtureSafeStorage(passwords: ["Chrome Safe Storage": "fixture"]))
        let sync = ImportCookieSync(store: fixture.store, grants: nil, destination: jar, keys: keys,
                                    stateDirectory: fixture.root.appending(path: "state")) { _ in }
        await sync.setTiming(debounce: 100, minimumInterval: 0)
        await sync.setPaused(false)
        await Self.until { await sync.stats.scans >= 1 }
        try Self.cookies(fixture.file, hosts: [".one.example", ".two.example"])
        await Self.until { keys.asked > 0 }
        #expect(keys.asked == 1, "the change reached the Keychain read")
        await sync.setPaused(true)
        try await Task.sleep(for: .milliseconds(1_000))
        #expect(await jar.hosts.isEmpty, "off mid-import, the import wrote cookies")
    }

    @Test func theProfileFolderIsTheCookieFilesOwn() {
        let record = ImportSourceRecord(browser: .chrome, profileDirectory: "Profile 1", displayName: "Google Chrome",
                                        proposedProfileID: "p", targetProfileID: "p", profileName: "Work")
        let modern = ImportCookieSync.profile(record, file: URL(filePath: "/c/Profile 1/Network/Cookies"))
        #expect(modern.path.path == "/c/Profile 1")
        #expect(modern.displayName == "Work")
        #expect(ImportCookieSync.profile(record, file: URL(filePath: "/c/Profile 1/Cookies")).path.path == "/c/Profile 1")
    }

    @Test func aReimportWithoutCookiesKeepsTheirSync() async throws {
        let fixture = try await Self.fixture(hosts: [".one.example"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var bookmarksOnly = fixture.record
        bookmarksOnly.syncedCookieFile = nil
        try await fixture.store.save(ImportBatch(source: bookmarksOnly, kinds: [.bookmarks]))
        #expect(await fixture.store.cookieSyncedSources().map(\.syncedCookieFile) == [fixture.file])
        // A cookie import that wrote none (an empty or expired store) keeps it too.
        try await fixture.store.save(ImportBatch(source: bookmarksOnly, kinds: [.cookies]))
        #expect(await fixture.store.cookieSyncedSources().map(\.syncedCookieFile) == [fixture.file])
        try await fixture.store.stopCookieSync(sourceKey: fixture.record.sourceKey)
        #expect(await fixture.store.cookieSyncedSources().isEmpty)
    }
}
