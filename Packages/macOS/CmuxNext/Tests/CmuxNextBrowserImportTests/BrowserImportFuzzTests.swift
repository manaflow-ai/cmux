import CmuxFuzzSupport
@testable import CmuxNextBrowserImport
import CmuxNextCompat
import Foundation
import Testing

/// Seeded fuzz of browser and cookie import (plans/cmux-next/chrome-parity/p10-stability.md, task 025):
/// damaged Chrome, Firefox and Safari profiles through every reader the import runs on another browser's
/// files (cookies, sessions, bookmarks, history, saved passwords, export archives), then whole profiles
/// through ``BrowserImporter``. Chrome fuzzes the same importers: chrome/utility/importer/
/// (`firefox_importer_unittest.cc`, `safari_importer_unittest.mm`) reads foreign profiles in a sandboxed
/// utility process, and components/history and sql are fuzzed with corrupt SQLite (sql/recover_module
/// fuzzers). When the readers move into the sandboxed import service, these same
/// cases run against it.
///
/// The property: any file gives a value or a typed error, never a trap; what is read is safe to hand on
/// (``ImportFuzzOracle``); every row is imported or counted by its skip reason; a profile that fails is
/// reported on its own and the others import in full.
///
/// It runs only with `CMUX_IMPORT_FUZZ=1`; agents run it on the fleet, CI does not (Lawrence 2026-10-23):
///
/// ```
/// CMUX_IMPORT_FUZZ=1 swift test --filter BrowserImport
/// CMUX_IMPORT_FUZZ=1 CMUX_FUZZ_DEADLINE=$(( $(date +%s) + 300 )) swift test --filter BrowserImportFuzzTests
/// ```
///
/// The runs are CmuxFuzzSupport `FuzzRun`s: `CMUX_FUZZ_SEED` and `CMUX_FUZZ_ITERATIONS`
/// replay a failure, and with `CMUX_FUZZ_ARTIFACTS` set a trap leaves its input behind
/// (`BrowserImport.<run>.inflight`).
@Suite(
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["CMUX_IMPORT_FUZZ"] == "1",
        "set CMUX_IMPORT_FUZZ=1; agents run it on the fleet (Lawrence 2026-10-23)"
    )
)
struct BrowserImportFuzzTests {
    /// Two minutes past a long run's budget, so the limit stops a hang and never a long run.
    static let timeLimitMinutes: Int = {
        let budget = (try? FuzzEnvironment.current())?.longModeBudget(from: Date()) ?? 0
        return 2 + Int((budget / 60).rounded(.up))
    }()

    /// Every byte format, from seeds of each, damaged by byte and token edits.
    @Test(.timeLimit(.minutes(BrowserImportFuzzTests.timeLimitMinutes)))
    func oneInputTakesAnyBytes() throws {
        let run = try FuzzRun("BrowserImport.oneInput", seed: 0x1A90_0025_0001, iterations: 20_000)
        let mutator = FuzzMutator(dictionary: ImportFuzzCases.binaryTokens + ImportFuzzCases.jsonTokens, maximumCount: 1 << 14)
        try run.forEachInput(try run.corpus(seeds: ImportFuzzCases.byteSeeds), mutator: mutator) { try ImportFuzzCases.oneInput($0) }
    }

    /// JSON files (Chromium bookmarks, Arc's sidebar, exported history, Firefox's session and search
    /// store) with JSON-token edits, so damage lands in values and structure, not only in the bytes.
    @Test(.timeLimit(.minutes(BrowserImportFuzzTests.timeLimitMinutes)))
    func jsonProfilesKeepTheirPromises() throws {
        let run = try FuzzRun("BrowserImport.json", seed: 0x1A90_0025_0002, iterations: 10_000)
        let seeds = [BookmarksFixture.chromium, BookmarksFixture.arc, ExportedHistoryFixture.safari, ExportedHistoryFixture.takeout,
                     MozLz4Fixture.session, MozLz4Fixture.searchEngines]
        let mutator = FuzzMutator(dictionary: ImportFuzzCases.jsonTokens, maximumEdits: 6, maximumCount: 1 << 14)
        try run.forEachInput(try run.corpus(seeds: seeds), mutator: mutator) { json in
            try ImportFuzzCases.chromiumBookmarks(json)
            try ImportFuzzCases.arcSidebar(json)
            try ImportFuzzCases.exportedHistory(json)
            try ImportFuzzCases.firefoxSessionJSON(json)
            try ImportFuzzCases.firefoxSearchEngine(json)
        }
    }

    /// Password CSV exports with CSV-token edits: every row becomes a sign-in or a counted skip.
    @Test(.timeLimit(.minutes(BrowserImportFuzzTests.timeLimitMinutes)))
    func passwordCSVRowsAreImportedOrCounted() throws {
        let run = try FuzzRun("BrowserImport.csv", seed: 0x1A90_0025_0003, iterations: 10_000)
        let mutator = FuzzMutator(dictionary: ImportFuzzCases.csvTokens, maximumEdits: 6, maximumCount: 1 << 12)
        try run.forEachInput(try run.corpus(seeds: [PasswordCSVFixture.sample]), mutator: mutator) { try ImportFuzzCases.passwordCSV($0) }
    }

    /// Browser databases with any cell in any column, and some damaged on disk: each reader returns or
    /// throws its own error, and accounts for every row it read. Also Chromium's `Local State` over
    /// profile folders, and a file that is no database.
    @Test(.timeLimit(.minutes(BrowserImportFuzzTests.timeLimitMinutes)))
    func databaseRowsAreImportedOrCounted() throws {
        try FuzzRun("BrowserImport.database", seed: 0x1A90_0025_0004, iterations: 1_500).forEach { rng in
            try ImportFuzzFiles.scratch("db") { (folder: URL) -> Void in
                switch rng.below(9) {
                case 0: try ImportFuzzDatabases.chromiumCookies(&rng, in: folder)
                case 1: try ImportFuzzDatabases.firefoxCookies(&rng, in: folder)
                case 2: try ImportFuzzDatabases.chromiumHistory(&rng, in: folder)
                case 3: try ImportFuzzDatabases.safariHistory(&rng, in: folder)
                case 4: try ImportFuzzDatabases.firefoxPlaces(&rng, in: folder)
                #if !CMUX_NO_PASSWORD_IMPORT
                case 5: try ImportFuzzDatabases.chromiumLogins(&rng, in: folder)
                case 6: try ImportFuzzDatabases.firefoxLogins(&rng, in: folder)
                #endif
                case 7: try ImportFuzzDatabases.chromiumLocalState(&rng, in: folder)
                default:
                    // A database file that is not one: the readers refuse it with their error.
                    let file = folder.appending(path: "History")
                    try rng.bytes(4096).write(to: file)
                    do {
                        _ = try ChromiumHistoryReader().read(file, limit: 10)
                    } catch is SQLiteSnapshot.Failure {}
                }
            }
        }
    }

    /// Whole profiles of three browsers, a random set of their files damaged or gone: each profile is
    /// reported once, imported or failed with a reason; cookies and passwords carry their own report or
    /// reason; an undamaged profile imports in full whatever happened to the others.
    @Test(.timeLimit(.minutes(BrowserImportFuzzTests.timeLimitMinutes)))
    func damagedProfilesAreReportedOneByOne() async throws {
        let run = try FuzzRun("BrowserImport.profiles", seed: 0x1A90_0025_0005, iterations: 300)
        // Each iteration waits for the importer actor: on a thread of its own, never on one of the Swift
        // concurrency pool, which the importer needs.
        try await ImportFuzzThread.run("BrowserImportFuzz profiles") {
            _ = try run.forEach { rng in
                try ImportFuzzFiles.scratch("home") { (home: URL) -> Void in
                    var profiles = try ImportFuzzHome(home)
                    try profiles.damage(&rng)
                    let checked = profiles
                    try ImportFuzzThread.wait { try await checked.check() }
                }
            }
        }
    }
}

/// A dedicated thread for runs whose iterations wait for async work, and the wait itself.
struct ImportFuzzThread {
    static func run(_ name: String, _ body: @escaping @Sendable () throws -> Void) async throws {
        let result: Result<Void, any Error> = await withCheckedContinuation { continuation in
            let thread = Thread {
                do {
                    try body()
                    continuation.resume(returning: .success(()))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
            thread.name = name
            thread.qualityOfService = .utility
            thread.start()
        }
        try result.get()
    }

    /// Runs `work` on the concurrency pool and blocks this (dedicated, non-pool) thread until it ends.
    static func wait(_ work: @escaping @Sendable () async throws -> Void) throws {
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        Task {
            let result: Result<Void, any Error>
            do {
                try await work()
                result = .success(())
            } catch {
                result = .failure(error)
            }
            outcome.set(result)
            done.signal()
        }
        done.wait()
        try outcome.get()
    }

    /// The task's result, handed from the pool thread to the waiting one.
    final class Outcome: Sendable {
        private let result = Mutex<Result<Void, any Error>?>(nil)

        func set(_ value: Result<Void, any Error>) {
            result.withLock { $0 = value }
        }

        func get() throws {
            try result.withLock { $0 }?.get()
        }
    }
}
