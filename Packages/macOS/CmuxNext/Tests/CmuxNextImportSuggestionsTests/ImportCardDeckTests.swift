import CmuxNextBrowserImport
@testable import CmuxNextImportSuggestions
import Foundation
import Testing

/// Which cards each surface shows, dismissals that stick until something new
/// appears, the Chief's requests, and jobs that survive a relaunch.
struct ImportCardDeckTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static let chrome = ImportFinding(id: "browser.chrome", kind: .browser, browser: .chrome, name: "Chrome",
                                      profiles: [.init(directoryName: "Default", kinds: [.history, .bookmarks, .cookies]),
                                                 .init(directoryName: "Profile 1", kinds: [.history, .passwords])])
    static let claude = ImportFinding(id: "agents.claudeCode", kind: .claudeCode, name: "Claude Code", count: 412)
    static let safari = ImportFinding(id: "browser.safari", kind: .browser, browser: .safari, name: "Safari",
                                      profiles: [.init(directoryName: "Safari", kinds: [.history])], access: .needsFullDiskAccess)
    static let ghostty = ImportFinding(id: "terminal.ghostty", kind: .ghostty, name: "Ghostty", access: .inUse)

    static func deck(_ findings: [ImportFinding], state: ImportSuggestionState = ImportSuggestionState(),
                     jobs: ImportJobLedger = ImportJobLedger()) -> ImportCardDeck {
        ImportCardDeck(findings: findings, state: state, jobs: jobs)
    }

    @Test func homeShowsOnlyWhatOneClickImports() {
        let cards = Self.deck([Self.chrome, Self.safari, Self.ghostty, Self.claude]).cards(for: .home, now: Self.now)
        #expect(cards.map(\.id) == ["browser.chrome", "agents.claudeCode"])
        #expect(cards[0].primary?.action == .start)
        #expect(cards[0].secondary.map(\.action) == [.more, .dismiss])
        #expect(!cards[0].facts.isEmpty && !cards[0].benefit.isEmpty)
    }

    @Test func settingsListsEverythingFound() {
        let cards = Self.deck([Self.chrome, Self.safari, Self.ghostty]).cards(for: .settings, now: Self.now)
        #expect(cards.map(\.id) == ["browser.chrome", "browser.safari", "terminal.ghostty"])
        #expect(cards[1].state == .info && cards[1].primary?.action == .open)
        #expect(cards[2].state == .info && cards[2].secondary.isEmpty)
    }

    @Test func aDismissedCardStaysGoneUntilSomethingNewAppears() {
        var state = ImportSuggestionState()
        state.dismiss(Self.chrome)
        state.dismiss(Self.claude)
        #expect(Self.deck([Self.chrome, Self.claude], state: state).cards(for: .newTab, now: Self.now).isEmpty)
        // More sessions is ordinary use: still gone.
        var grown = Self.claude
        grown.count = 900
        // A new Chrome profile is something new: back.
        var newProfile = Self.chrome
        newProfile.profiles.append(.init(directoryName: "Profile 2", kinds: [.history]))
        let cards = Self.deck([newProfile, grown], state: state).cards(for: .newTab, now: Self.now)
        #expect(cards.map(\.id) == ["browser.chrome"])
        // Settings keeps the dismissed one, with Show Again.
        let settings = Self.deck([Self.claude], state: state).cards(for: .settings, now: Self.now)
        #expect(settings.first?.dismissed == true)
        #expect(settings.first?.secondary.map(\.action) == [.restore])
    }

    @Test func aChiefRequestLeadsAndNamesItsSite() throws {
        var state = ImportSuggestionState()
        let site = try #require(ImportRequest.site("https://GitHub.com/login"))
        state.raise(ImportRequest(browser: .chrome, site: site, reason: "The page asks to sign in.", requestedAt: Self.now))
        let cards = Self.deck([Self.chrome], state: state).cards(for: .home, now: Self.now)
        #expect(cards.map(\.id) == ["request.cookies.chrome.github.com", "browser.chrome"])
        #expect(cards[0].reason == "The page asks to sign in.")
        #expect(cards[0].title.contains("github.com"))
    }

    @Test(arguments: ["", "localhost", "github.com/../x", "a b.com", "-x.com", "x..com", "x.com."])
    func aRequestNamesOnlyAHost(_ text: String) {
        #expect(ImportRequest.site(text) == nil)
    }

    @Test func surfacesCapTheirCards() {
        let many = (0..<8).map { ImportFinding(id: "agents.\($0)", kind: .codex, name: "Codex", count: 1) }
        #expect(Self.deck(many).cards(for: .newTab, now: Self.now).count == 3)
        #expect(Self.deck(many).cards(for: .home, now: Self.now).count == 4)
        #expect(Self.deck(many).cards(for: .settings, now: Self.now).count == 8)
    }

    // MARK: Jobs

    @Test func aBrowserJobHasOneStepPerProfileWithoutPasswords() {
        let job = ImportJob(finding: Self.chrome, now: Self.now)
        #expect(job.steps.map(\.profile) == ["Default", "Profile 1"])
        #expect(job.steps.map(\.kinds) == [[.history, .bookmarks, .cookies], [.history]])
        #expect(job.steps.map(\.intoDefault) == [true, false])
    }

    @Test func aRunningJobShowsProgressAndFinishesWithItsCounts() {
        var job = ImportJob(finding: Self.chrome, now: Self.now)
        job.progressed(0.5, now: Self.now)
        #expect(job.fraction == 0.25)
        job.finishedStep(0, counts: ImportCounts(bookmarks: 3, history: 10, cookies: 4), now: Self.now)
        #expect(job.fraction == 0.5 && job.phase == .running)
        job.finishedStep(1, counts: ImportCounts(history: 2), now: Self.now)
        #expect(job.phase == .done && job.counts.history == 12)
        var ledger = ImportJobLedger()
        ledger.put(job)
        let card = Self.deck([], jobs: ledger).cards(for: .home, now: Self.now)
        #expect(card.first?.state == .done && card.first?.secondary.map(\.action) == [.hide])
        // A day later Home lets it go; Settings still lists it.
        let later = Self.now.addingTimeInterval(ImportCardDeck.doneLingers + 1)
        #expect(Self.deck([], jobs: ledger).cards(for: .home, now: later).isEmpty)
        #expect(Self.deck([], jobs: ledger).cards(for: .settings, now: later).count == 1)
    }

    @Test func aJobCutOffByAQuitIsPausedAndResumesOnlyWhenNoPromptIsLeft() throws {
        var ledger = ImportJobLedger()
        var chrome = ImportJob(finding: Self.chrome, now: Self.now)
        chrome.finishedStep(1, counts: ImportCounts(), now: Self.now)
        ledger.put(chrome)
        let firefox = ImportFinding(id: "browser.firefox", kind: .browser, browser: .firefox, name: "Firefox",
                                    profiles: [.init(directoryName: "Profiles/a", kinds: [.history, .cookies])])
        ledger.put(ImportJob(finding: firefox, now: Self.now))
        let url = FileManager.default.temporaryDirectory.appending(path: "import-jobs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try ledger.save(to: url)
        var relaunched = ImportJobLedger.load(from: url)
        relaunched.relaunched(now: Self.now)
        let chromeAfter = try #require(relaunched.job("browser.chrome"))
        #expect(chromeAfter.phase == .paused && chromeAfter.pause == .interrupted)
        #expect(chromeAfter.steps.map(\.done) == [false, true])
        // Chrome's cookies need a Keychain prompt, so it waits for Resume; Firefox's need none.
        #expect(!chromeAfter.resumesQuietly)
        #expect(relaunched.job("browser.firefox")?.resumesQuietly == true)
        let card = try #require(Self.deck([], jobs: relaunched).cards(for: .home, now: Self.now).first { $0.id == "browser.chrome" })
        #expect(card.state == .paused && card.primary?.action == .resume)
    }

    @Test func anUnreadableLedgerStartsEmpty() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "import-jobs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{not json".utf8).write(to: url)
        #expect(ImportJobLedger.load(from: url).jobs.isEmpty)
    }
}
