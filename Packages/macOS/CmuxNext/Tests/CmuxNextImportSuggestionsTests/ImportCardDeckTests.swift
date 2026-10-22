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
    /// cmux Classic with a saved session whose workspaces all came over already.
    static let classicAllHere = ImportFinding(id: "cmux.classic", kind: .cmuxClassic, name: "cmux Classic", count: 0)

    static func deck(_ findings: [ImportFinding], state: ImportSuggestionState = ImportSuggestionState(),
                     jobs: ImportJobLedger = ImportJobLedger()) -> ImportCardDeck {
        ImportCardDeck(findings: findings, state: state, jobs: jobs)
    }

    /// Nothing pops up on Home or New Tab by itself: what a scan found and the imports the person
    /// started wait in Settings › Import.
    @Test(arguments: [ImportCardDeck.Surface.home, .newTab])
    func homeAndNewTabNeverSuggestWhatAScanFound(_ surface: ImportCardDeck.Surface) {
        let iterm = ImportFinding(id: "terminal.iterm2", kind: .iterm2, name: "iTerm2", count: 1)
        let codex = ImportFinding(id: "agents.codex", kind: .codex, name: "Codex", count: 17_021)
        var ledger = ImportJobLedger()
        var paused = ImportJob(finding: Self.chrome, now: Self.now)
        paused.paused(.interrupted, now: Self.now)
        ledger.put(paused)
        #expect(Self.deck([Self.chrome], jobs: ledger).cards(for: surface, now: Self.now).isEmpty)
        let deck = Self.deck([Self.chrome, Self.safari, Self.ghostty, Self.claude, iterm, codex])
        #expect(deck.cards(for: surface, now: Self.now).isEmpty)
        #expect(deck.list(for: surface, now: Self.now).cards.isEmpty)
        let settings = deck.cards(for: .settings, now: Self.now)
        #expect(settings.map(\.id) == ["browser.chrome", "browser.safari", "terminal.ghostty", "agents.claudeCode", "terminal.iterm2", "agents.codex"])
        #expect(settings[0].primary?.action == .start)
        #expect(settings[0].secondary.map(\.action) == [.more, .dismiss])
        #expect(!settings[0].facts.isEmpty && !settings[0].benefit.isEmpty)
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
        #expect(Self.deck([Self.chrome, Self.claude], state: state).cards(for: .settings, now: Self.now).allSatisfy { $0.dismissed })
        // More sessions is ordinary use: still gone.
        var grown = Self.claude
        grown.count = 900
        // A new Chrome profile is something new: back.
        var newProfile = Self.chrome
        newProfile.profiles.append(.init(directoryName: "Profile 2", kinds: [.history]))
        let cards = Self.deck([newProfile, grown], state: state).cards(for: .settings, now: Self.now)
        #expect(cards.filter { !$0.dismissed }.map(\.id) == ["browser.chrome"])
        // A profile imported elsewhere (Chrome holds less now) is not new: still gone.
        var fewer = Self.chrome
        fewer.profiles = Array(fewer.profiles.prefix(1))
        fewer.profiles[0].kinds = Array(fewer.profiles[0].kinds.prefix(1))
        #expect(Self.deck([fewer], state: state).cards(for: .settings, now: Self.now).allSatisfy { $0.dismissed })
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
        // Only the request: it answers a sign-in the person just ran into; Chrome's own card waits in Settings.
        #expect(cards.map(\.id) == ["request.cookies.chrome.github.com"])
        #expect(cards[0].reason == "The page asks to sign in.")
        #expect(cards[0].title.contains("github.com"))
    }

    @Test(arguments: ["", "localhost", "github.com/../x", "a b.com", "-x.com", "x..com", "x.com."])
    func aRequestNamesOnlyAHost(_ text: String) {
        #expect(ImportRequest.site(text) == nil)
    }

    /// The import keeps every cookie of the site and its subdomains, so a public suffix would bring
    /// every site under it: `co.uk` is every UK company's sign-in, `github.io` every Pages site's.
    @Test(arguments: ["co.uk", "CO.UK", ".com.au", "https://ne.jp/login", "gov.br", "github.io", "vercel.app", "10.0.0.1", "192.168.1.20"])
    func aRequestNeverNamesAPublicSuffix(_ text: String) {
        #expect(ImportRequest.site(text) == nil)
    }

    @Test(arguments: [("bbc.co.uk", "bbc.co.uk"), ("https://Someone.GitHub.io/x", "someone.github.io"), ("go.dev", "go.dev"),
                      ("accounts.google.com", "accounts.google.com"), ("linear.app", "linear.app")])
    func aSiteUnderAPublicSuffixIsOneSite(_ text: String, _ site: String) {
        #expect(ImportRequest.site(text) == site)
    }

    /// A page's Import asks natively first only where the start reads another app's data.
    @Test func onlyAStartThatReadsAnotherAppAsksFirst() {
        #expect(Set(ImportSourceKind.allCases.filter(\.startReadsAnotherApp)) == [.browser, .iterm2])
        #expect(ImportSuggestionStrings.confirmTitle("Chrome").contains("Chrome"))
        #expect(ImportSuggestionStrings.confirmButton(.resume) == ImportSuggestionStrings.resume)
    }

    /// The raiser rides with the request (the consent panel names it); a request saved before that reads as nil.
    @Test func aRequestKeepsWhoRaisedIt() throws {
        let raised = ImportRequest(browser: .chrome, site: "github.com", reason: "", requestedAt: Self.now, raisedBy: "mcp",
                                   agentSession: "session-1", terminal: nil)
        let decoded = try JSONDecoder.importJobs.decode(ImportRequest.self, from: JSONEncoder.importJobs.encode(raised))
        #expect(decoded == raised)
        let older = try JSONEncoder.importJobs.encode(ImportRequest(browser: .chrome, site: "github.com", reason: "", requestedAt: Self.now))
        let legacy = try JSONDecoder.importJobs.decode(ImportRequest.self, from: older)
        #expect(legacy.raisedBy == nil && legacy.agentSession == nil && legacy.terminal == nil)
    }

    @Test func surfacesCapTheirCards() {
        var state = ImportSuggestionState()
        for index in 0..<8 {
            state.raise(ImportRequest(browser: .chrome, site: "site\(index).com", reason: "", requestedAt: Self.now))
        }
        #expect(Self.deck([], state: state).cards(for: .newTab, now: Self.now).count == 3)
        #expect(Self.deck([], state: state).cards(for: .home, now: Self.now).count == 4)
        #expect(Self.deck([], state: state).cards(for: .settings, now: Self.now).count == ImportSuggestionState.maximumRequests)
    }

    /// Everything classic saved is already here: Home and New Tab have nothing one click brings,
    /// while Settings › Import keeps the card so the person can run the import again.
    @Test func settingsKeepsClassicOnceEverythingCameOver() throws {
        let deck = Self.deck([Self.classicAllHere])
        #expect(deck.cards(for: .home, now: Self.now).isEmpty)
        #expect(deck.cards(for: .newTab, now: Self.now).isEmpty)
        let card = try #require(deck.cards(for: .settings, now: Self.now).first)
        #expect(card.id == "cmux.classic" && card.state == .ready)
        #expect(card.primary?.action == .start && card.primary?.title == "Import Again")
        #expect(card.facts != ImportSuggestionStrings.workspaces(0) && !card.facts.isEmpty && !card.benefit.isEmpty)
        // Workspaces still to bring: the one-click card, in Settings only (Home pops up nothing).
        var more = Self.classicAllHere
        more.count = 2
        #expect(Self.deck([more]).cards(for: .home, now: Self.now).isEmpty)
        let offered = try #require(Self.deck([more]).cards(for: .settings, now: Self.now).first)
        #expect(offered.primary?.title == ImportSuggestionStrings.importWorkspaces)
    }

    /// A finished classic import stays offered again in Settings › Import, with what it brought.
    /// Home and New Tab show nothing for it.
    @Test func aFinishedClassicImportOffersItAgainInSettings() throws {
        var job = ImportJob(finding: Self.classicAllHere, now: Self.now)
        job.importedClassic(0, now: Self.now)
        var ledger = ImportJobLedger()
        ledger.put(job)
        let deck = Self.deck([Self.classicAllHere], jobs: ledger)
        let settings = deck.cards(for: .settings, now: Self.now).first
        #expect(settings?.state == .done && settings?.primary?.action == .start && settings?.primary?.title == "Import Again")
        #expect(settings?.status == ImportSuggestionStrings.importedSessions(0))
        #expect(deck.cards(for: .home, now: Self.now).isEmpty)
        #expect(deck.cards(for: .newTab, now: Self.now).isEmpty)
        job.importedClassic(2, now: Self.now)
        ledger.put(job)
        #expect(Self.deck([Self.classicAllHere], jobs: ledger).cards(for: .home, now: Self.now).isEmpty)
        let done = try #require(Self.deck([Self.classicAllHere], jobs: ledger).cards(for: .settings, now: Self.now).first)
        #expect(done.state == .done && done.status == ImportSuggestionStrings.importedSessions(2))
    }

    /// Resume and Try Again start over from 0, not at the fraction the cut-off run had reached.
    @Test func aResumedClassicJobStartsAtZeroProgress() {
        var job = ImportJob(finding: Self.classicAllHere, now: Self.now)
        job.progressed(0.6, now: Self.now)
        job.paused(.interrupted, now: Self.now)
        job.resumed(now: Self.now)
        #expect(job.phase == .running && job.fraction == 0)
        job.progressed(0.4, now: Self.now)
        job.failed(.importFailed, now: Self.now)
        job.resumed(now: Self.now)
        #expect(job.fraction == 0)
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
        // A finished import leaves Home and New Tab at once; Settings › Import keeps it.
        #expect(Self.deck([], jobs: ledger).cards(for: .home, now: Self.now).isEmpty)
        #expect(Self.deck([Self.chrome], jobs: ledger).cards(for: .newTab, now: Self.now).isEmpty)
        let card = Self.deck([], jobs: ledger).cards(for: .settings, now: Self.now)
        #expect(card.first?.state == .done && card.first?.secondary.map(\.action) == [.hide])
    }

    @Test func onlyStartResumeAndTryAgainReadAnotherAppsData() {
        #expect(ImportCardAction.allCases.filter(\.startsWork) == [.start, .resume, .retry])
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
        let card = try #require(Self.deck([], jobs: relaunched).cards(for: .settings, now: Self.now).first { $0.id == "browser.chrome" })
        #expect(card.state == .paused && card.primary?.action == .resume)
    }

    @Test func anUnreadableLedgerStartsEmpty() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "import-jobs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{not json".utf8).write(to: url)
        #expect(ImportJobLedger.load(from: url).jobs.isEmpty)
    }
}
