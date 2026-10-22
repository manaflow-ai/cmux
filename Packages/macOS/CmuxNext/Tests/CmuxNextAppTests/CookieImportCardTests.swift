import CmuxNextActions
import CmuxNextBrowser
import CmuxNextBrowserImport
@testable import CmuxNextCookieImport
import Foundation
import SQLite3
import Testing

/// The cookie import permission card (`cmux browser import-cookies` from an agent or a Home
/// Chief): what the card says, that it asks once and never allows by itself, the audit ledger,
/// Remove, and the whole run end to end over a Firefox profile on disk (no Keychain).
@MainActor
@Suite(.serialized) struct CookieImportCardTests {
    // MARK: Text the agent writes

    @Test func agentTextCannotRestyleTheCard() {
        let text = CookieImportText()
        #expect(text.shown("log in\n\n  to\tGitHub") == "log in to GitHub")
        #expect(text.shown("pay \u{202E}moc.knab\u{202C} now") == "pay moc.knab now", "a right-to-left override is dropped")
        #expect(text.shown("a\u{200B}b\u{0007}c") == "ab c")
        let long = String(repeating: "x", count: 1000)
        #expect(text.shown(long).count == CookieImportText.reasonLimit)
        #expect(text.shown(long).hasSuffix("…"))
    }

    @Test func sitesShowInASCIISoALookAlikeCannotPass() throws {
        let text = CookieImportText()
        #expect(text.site(".GitHub.com") == "github.com")
        let cyrillic = try #require(text.site("gооgle.com"), "Cyrillic o's")
        #expect(cyrillic.hasPrefix("xn--"), "shown as punycode, never as google.com")
        #expect(text.site("not a host") == nil)
        #expect(text.site("<script>") == nil)
    }

    @Test func aSiteThatIsNotAHostRefusesTheRun() {
        #expect(throws: CookieImportRefusal.self) { try CookieImportService.filter("github.com, <img src=x>") }
        #expect((try? CookieImportService.filter("https://GitHub.com/login, bücher.de"))?.domains == ["github.com", "xn--bcher-kva.de"])
    }

    // MARK: What the card says

    private static func request(kind: CookieImportRequester.Kind = .homeChief, domains: [String] = ["github.com"],
                                prompt: CookieImportRequest.Prompt = .keychain(service: "Chrome Safe Storage")) -> CookieImportRequest {
        CookieImportRequest(requester: CookieImportRequester(kind: kind, name: "Lawrence's Chief"), reason: "Open your GitHub PRs", source: "Google Chrome · Work",
                            prompt: prompt, domains: domains, target: "Default")
    }

    @Test func askingCardSaysWhoWhyWhatWhereAndTheKeychainStep() {
        let text = CookieImportCardText(Self.request(), phase: .asking, isArmed: false, showsSites: false, deadlineSeconds: 180)
        #expect(text.title == CookieImportStrings.titleChief)
        #expect(text.requester == CookieImportStrings.homeChief("Lawrence's Chief"))
        #expect(text.reason == "Open your GitHub PRs")
        #expect(text.rows.map(\.value) == ["Google Chrome · Work", "github.com", "Default"])
        #expect(text.warning == nil)
        #expect(text.note?.contains("Chrome Safe Storage") == true)
        #expect(text.note?.contains("Always Allow") == true, "it says to pick Allow, not Always Allow")
        #expect(text.buttons.map(\.id) == [.deny, .allow])
        #expect(text.buttons.first { $0.id == .allow }?.isEnabled == false, "Allow waits for the arming beat")
        #expect(!text.buttons.contains { $0.id == .showRequester }, "a Home Chief has no tab to show")
    }

    @Test func everySiteIsWarnedAndSafariNamesFullDiskAccess() {
        let text = CookieImportCardText(Self.request(domains: [], prompt: .fullDiskAccess), phase: .asking, isArmed: true, showsSites: false,
                                        deadlineSeconds: 180)
        #expect(text.warning == CookieImportStrings.everySiteWarning)
        #expect(text.rows[1].value == CookieImportStrings.allSites)
        #expect(text.note?.hasPrefix(CookieImportStrings.afterAllowSafari) == true)
        #expect(text.buttons.first { $0.id == .allow }?.isEnabled == true)
    }

    @Test func finishedCardListsSitesWithCountsAndOffersRemove() {
        let cookies = [ImportedCookieIdentity(name: "a", domain: ".github.com", path: "/", secure: true),
                       ImportedCookieIdentity(name: "b", domain: "github.com", path: "/", secure: true),
                       ImportedCookieIdentity(name: "c", domain: "gist.github.com", path: "/", secure: true)]
        let record = CookieImportRecord(date: Date(), requester: .init(kind: "homeChief", name: ""), reason: "", source: "Chrome",
                                        targetProfileID: "default", targetProfileName: "Default", requestedSites: ["github.com"], outcome: .imported,
                                        report: CookieImportReport(written: 3), cookies: cookies)
        #expect(record.sites == [.init(host: "github.com", count: 2), .init(host: "gist.github.com", count: 1)])
        #expect(record.canRemove)
        let text = CookieImportCardText(Self.request(), phase: .imported(record), isArmed: true, showsSites: false, deadlineSeconds: 180)
        #expect(text.rows.first?.value == "github.com (2), gist.github.com (1)")
        #expect(text.buttons.map(\.id) == [.remove, .showAll, .dismiss])
        #expect(!text.plainText.contains("Open your GitHub PRs"), "the finished card drops the ask")
    }

    @Test func requesterOfAHomeChiefTurnIsTheChief() {
        var invocation = ActionInvocation(origin: .cli)
        invocation.callerAgentSession = "turn-7"
        invocation.callerHomeChat = true
        let requester = CookieImportRequester(invocation, among: []) { _ in (title: "Lawrence's Chief", preview: "Opening GitHub") }
        #expect(requester == CookieImportRequester(kind: .homeChief, name: "Lawrence's Chief", latestMessage: "Opening GitHub"))
        #expect(CookieImportService.needsReason(invocation), "a Chief must say why")
    }

    // MARK: The ask

    @Test func anEarlyAllowIsIgnoredAndOnlyTheFirstAnswerCounts() async {
        let clock = ManualClock()
        let ask = CookieImportAsk(request: Self.request(), limit: .seconds(100_000), armDelay: .milliseconds(800), clock: clock)
        ask.shown()
        ask.answer(.allow)
        #expect(ask.answered == nil, "Allow before the arming beat does nothing")
        // Small steps: the arming timer reads the clock when its task starts, so one big jump could land before it sleeps.
        for _ in 0..<200 where !ask.isArmed {
            clock.advance(by: .milliseconds(250))
            await waitUntil { ask.isArmed }
        }
        #expect(ask.isArmed)
        ask.answer(.allow)
        ask.answer(.deny)
        #expect(ask.answered == .allow)
        #expect(ask.phase == .reading)
        #expect(await ask.nextAnswer() == .allow)
    }

    @Test func noAnswerDeniesAtTheLimit() async throws {
        let clock = ManualClock()
        let ask = CookieImportAsk(request: Self.request(), limit: .seconds(180), armDelay: .zero, clock: clock)
        ask.shown()
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(181))
        #expect(await ask.nextAnswer() == .timedOut)
    }

    @Test func closingAnAskDenies() async {
        let ask = CookieImportAsk(request: Self.request(), armDelay: .zero)
        ask.shown()
        ask.dismiss()
        #expect(await ask.nextAnswer() == .deny)
        #expect(ask.isDismissed)
    }

    // MARK: Ledger

    @Test func ledgerKeepsNoValueAndIsOwnerOnly() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cookie-ledger-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "cookie-imports.json")
        let ledger = CookieImportLedger(file: file)
        let record = CookieImportRecord(date: Date(timeIntervalSince1970: 1_800_000_000), requester: .init(kind: "agentChat", name: "a49"),
                                        reason: "PRs", source: "Chrome", targetProfileID: "default", targetProfileName: "Default",
                                        requestedSites: ["github.com"], outcome: .imported, report: CookieImportReport(written: 1),
                                        cookies: [ImportedCookieIdentity(name: "user_session", domain: "github.com", path: "/", secure: true)])
        await ledger.append(record)
        let reread = await CookieImportLedger(file: file).records()
        #expect(reread == [record])
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let removed = await ledger.markRemoved(record.id, at: Date(timeIntervalSince1970: 1_800_000_100))
        #expect(removed?.canRemove == false)
        for index in 0..<(CookieImportLedger.limit + 5) {
            await ledger.append(CookieImportRecord(date: Date(), requester: .init(kind: "person", name: ""), reason: "\(index)", source: "Chrome",
                                                   targetProfileID: "default", targetProfileName: "Default", requestedSites: [], outcome: .denied))
        }
        #expect(await ledger.records().count == CookieImportLedger.limit)
    }

    @Test func removalIsAnExpiredWriteOfTheSameCookie() throws {
        let write = try #require(ChromiumCookieDestination.removal(for: ImportedCookieIdentity(name: "SID", domain: "github.com", path: "/", secure: true)))
        #expect(write.value.isEmpty)
        #expect(write.domain.isEmpty, "a host-only cookie stays host-only, so the same cookie is replaced")
        #expect(write.url.absoluteString == "https://github.com/")
        #expect((write.expires ?? .distantFuture) < Date(timeIntervalSince1970: 100_000))
        let domain = try #require(ChromiumCookieDestination.removal(for: ImportedCookieIdentity(name: "SID", domain: ".github.com", path: "/a", secure: false)))
        #expect(domain.domain == ".github.com")
        #expect(domain.url.absoluteString == "http://github.com/a")
    }

    @Test func listingPutsOpenBrowsersFirstAndNamesThePrompt() {
        let chrome = BrowserSource(browser: .chrome, appURL: nil, profiles: [Self.profile("chrome", "Default", "Personal")])
        let firefox = BrowserSource(browser: ImportBrowser(rawValue: "firefox"), appURL: nil, profiles: [Self.profile("firefox", "Profiles/x.default", "default")])
        let listing = CookieSourceListing(sources: [chrome, firefox]) { $0.browser.rawValue == "firefox" }
        #expect(listing.entries.map(\.id) == ["firefox", "chrome"])
        #expect(listing.entries.map(\.isOpen) == [true, false])
        #expect(listing.entries.map(\.prompt) == ["none", "keychain"])
        #expect(listing.json.contains("\"open\":true"))
    }

    // MARK: End to end

    private static func profile(_ browser: String, _ directory: String, _ name: String, path: URL? = nil) -> BrowserSourceProfile {
        BrowserSourceProfile(browser: ImportBrowser(rawValue: browser), directoryName: directory, displayName: name,
                             path: path ?? URL(fileURLWithPath: "/tmp/\(browser)/\(directory)"), availability: [.cookies: .available])
    }

    /// A Firefox profile folder whose `cookies.sqlite` holds two github.com cookies and one bank cookie.
    private static func firefoxProfile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "cookie-card-ff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(folder.appending(path: "cookies.sqlite").path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        let future = Int(Date().timeIntervalSince1970) + 86_400 * 30
        let sql = """
        CREATE TABLE moz_cookies (id INTEGER PRIMARY KEY, originAttributes TEXT NOT NULL DEFAULT '', name TEXT, value TEXT, host TEXT, path TEXT,
          expiry INTEGER, lastAccessed INTEGER, creationTime INTEGER, isSecure INTEGER, isHttpOnly INTEGER, sameSite INTEGER);
        INSERT INTO moz_cookies (name, value, host, path, expiry, lastAccessed, creationTime, isSecure, isHttpOnly, sameSite) VALUES
          ('user_session', 'SECRET-GH-1', 'github.com', '/', \(future), 0, 0, 1, 1, 1),
          ('logged_in', 'SECRET-GH-2', '.github.com', '/', \(future), 0, 0, 1, 0, 1),
          ('bank_session', 'SECRET-BANK', 'bank.example', '/', \(future), 0, 0, 1, 1, 1);
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        return folder
    }

    /// Records what the import wrote and removed (values only to prove they never reach the ledger).
    private actor RecordingDestination: CookieDestination {
        var written: [ImportedCookie] = []
        var removed: [ImportedCookieIdentity] = []
        func setCookies(_ cookies: [ImportedCookie], profileID: String) async throws -> CookieWriteResult {
            written += cookies
            return CookieWriteResult(written: cookies.count, rejected: 0)
        }
        func removeCookies(_ cookies: [ImportedCookieIdentity], profileID: String) async throws -> Int {
            removed += cookies
            return cookies.count
        }
    }

    private final class Harness {
        let folder: URL
        let ledgerFile: URL
        let destination = RecordingDestination()
        var asks: [CookieImportAsk] = []
        var work: [ActionWork] = []
        let service: CookieImportService
        let ledger: CookieImportLedger

        @MainActor init() throws {
            folder = try CookieImportCardTests.firefoxProfile()
            ledgerFile = folder.appending(path: "ledger.json")
            ledger = CookieImportLedger(file: ledgerFile)
            let profile = CookieImportCardTests.profile("firefox", "Profiles/test.default", "default", path: folder)
            let sources = [BrowserSource(browser: ImportBrowser(rawValue: "firefox"), appURL: nil, profiles: [profile])]
            var presented: (CookieImportAsk) -> Void = { _ in }
            var tracked: (ActionWork) -> Void = { _ in }
            service = CookieImportService(host: CookieImportHost(
                requester: { invocation in CookieImportRequester(invocation, among: []) { _ in (title: "Lawrence's Chief", preview: nil) } },
                target: { _ in ("default", "Default") },
                window: { nil },
                presentInline: { ask in presented(ask); return true },
                reveal: { _ in },
                track: { tracked($0) },
                destination: destination,
                ledger: ledger,
                sources: { sources },
                keys: { FixtureSafeStorage(passwords: [:]) },
                armDelay: .zero))
            presented = { [unowned self] in asks.append($0) }
            tracked = { [unowned self] in work.append($0) }
        }

        deinit { try? FileManager.default.removeItem(at: folder) }

        static func chiefRun(domain: String) -> ActionInvocation {
            var invocation = ActionInvocation(arguments: ["from": .string("firefox"), "domain": .string(domain),
                                                          "reason": .string("Check your GitHub notifications")], origin: .cli)
            invocation.callerAgentSession = "turn-1"
            invocation.callerHomeChat = true
            return invocation
        }
    }

    @Test func allowImportsOnlyTheNamedSiteAuditsItAndRemoveTakesItBack() async throws {
        let harness = try Harness()
        try harness.service.run(Harness.chiefRun(domain: "github.com"))
        await waitUntil { !harness.asks.isEmpty }
        let ask = try #require(harness.asks.first)
        #expect(ask.request.requester.kind == .homeChief)
        #expect(await harness.destination.written.isEmpty, "nothing is read before Allow")
        ask.answer(.allow)
        let failure = await harness.work.first?.value
        #expect(failure == nil)
        let written = await harness.destination.written
        #expect(Set(written.map(\.name)) == ["user_session", "logged_in"], "the bank cookie stays out")
        let records = await harness.ledger.records()
        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(record.outcome == .imported)
        #expect(record.requester == .init(kind: "homeChief", name: "Lawrence's Chief"))
        #expect(record.reason == "Check your GitHub notifications")
        #expect(record.sites.map(\.host) == ["github.com"])
        let ledgerText = try String(contentsOf: harness.ledgerFile, encoding: .utf8)
        #expect(!ledgerText.contains("SECRET"), "no cookie value reaches the audit file")
        guard case .imported(let shown) = ask.phase else { Issue.record("the card shows the result, not \(ask.phase)"); return }
        #expect(shown.id == record.id)
        ask.remove()
        await waitUntil { if case .removed = ask.phase { true } else { false } }
        #expect(Set(await harness.destination.removed.map(\.name)) == ["user_session", "logged_in"])
        #expect(await harness.ledger.record(record.id)?.removedAt != nil)
        await #expect(throws: CookieImportRefusal.self) { try await harness.service.remove(record.id) }
    }

    @Test func denyReadsNothingAndIsAudited() async throws {
        let harness = try Harness()
        try harness.service.run(Harness.chiefRun(domain: "github.com"))
        await waitUntil { !harness.asks.isEmpty }
        harness.asks[0].answer(.deny)
        let failure = await harness.work.first?.value
        #expect(failure?.message == CookieImportStrings.denied)
        #expect(await harness.destination.written.isEmpty)
        #expect(await harness.ledger.records().map(\.outcome) == [.denied])
        #expect(harness.asks[0].isDismissed, "the denied card goes away")
    }

    @Test func aSecondAskWhileOneIsUpIsRefused() async throws {
        let harness = try Harness()
        try harness.service.run(Harness.chiefRun(domain: "github.com"))
        await waitUntil { !harness.asks.isEmpty }
        #expect(throws: CookieImportRefusal.self) { try harness.service.run(Harness.chiefRun(domain: "github.com")) }
        harness.asks[0].answer(.deny)
        _ = await harness.work.first?.value
    }

    /// Waits (bounded) for `condition`, yielding to the main actor between checks.
    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
        // Bounded: work off the main actor (the import's read) may need real time.
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }
}
