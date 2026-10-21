public import AppKit
public import CmuxNextActions
import CmuxNextAgentPane
public import CmuxNextBrowserImport
import CmuxNextCompat
public import CmuxNextImportSuggestions
import CmuxNextOnboarding
public import CmuxNextSettings
import Observation

/// The import suggestion cards for the whole app: it scans this Mac off the
/// main thread at launch and when cmux comes forward again (at most every
/// ``rescanInterval``), keeps the person's dismissals and the Chief's
/// requests, and runs each card's import as a job saved after every step, so
/// a quit or crash leaves it paused for Resume (or resumes it at launch when
/// no prompt is left). Home, New Tab (through `AgentPaneImportCards`) and
/// Settings › Import draw what ``list(for:)`` returns.
@MainActor
@Observable
public final class ImportSuggestionsCenter {
    public static let shared = ImportSuggestionsCenter()

    /// Every source the last scan found.
    public private(set) var findings: [ImportFinding] = []
    public private(set) var state: ImportSuggestionState
    public private(set) var ledger = ImportJobLedger()
    /// A scan is running.
    public private(set) var isScanning = false

    /// cmux comes forward this long after the last scan before the next one.
    public static let rescanInterval: TimeInterval = 10 * 60

    @ObservationIgnored private var host: ImportCardsHost?
    @ObservationIgnored private weak var registry: ActionRegistry?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let ledgerURL: URL
    @ObservationIgnored private var lastScan: Date?
    @ObservationIgnored private var running: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var activation: (any NSObjectProtocol)?
    @ObservationIgnored private var started = false
    @ObservationIgnored private let now: () -> Date

    init(defaults: UserDefaults = .standard, ledgerURL: URL = ImportSuggestionsCenter.defaultLedgerURL, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.ledgerURL = ledgerURL
        self.now = now
        state = ImportSuggestionState.load(from: defaults)
    }

    /// `Application Support/cmux-next/<bundle id>/import-jobs.json`.
    public nonisolated static var defaultLedgerURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "cmux-next", directoryHint: .isDirectory)
            .appending(path: Bundle.main.bundleIdentifier ?? "com.cmuxterm.app.next", directoryHint: .isDirectory)
            .appending(path: "import-jobs.json")
    }

    /// Debug Settings `browserImport.suggestionCards` (on by default).
    public var isEnabled: Bool { BrowserImportTunables.suggestionCards.value }

    /// Starts the cards once: the jobs a quit cut off, the first scan and the rescans.
    public func start(host: ImportCardsHost, registry: ActionRegistry) {
        self.host = host
        self.registry = registry
        guard !started else { return }
        started = true
        var loaded = ImportJobLedger.load(from: ledgerURL)
        loaded.relaunched(now: now())
        ledger = loaded
        saveLedger()
        state.expire(now: now())
        AgentPaneImportCards.shared.onAction = { [weak self] id, action in
            guard let action = ImportCardAction(rawValue: action) else { return }
            try? self?.perform(id, action)
        }
        follow()
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                            queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rescanIfStale() }
        }
        scan { [weak self] in
            // A job the quit cut off goes on by itself only when nothing it has left asks the person.
            guard let self else { return }
            for job in ledger.jobs where job.phase == .paused && job.pause == .interrupted && job.resumesQuietly {
                try? perform(job.id, .resume)
            }
        }
    }

    // MARK: Scan

    func rescanIfStale() {
        guard let lastScan else { return scan() }
        if now().timeIntervalSince(lastScan) >= Self.rescanInterval { scan() }
    }

    /// Scans this Mac off the main thread; `then` runs on the main actor after the findings land.
    public func scan(then: (@MainActor () -> Void)? = nil) {
        guard isEnabled, !isScanning, let host else { then?(); return }
        isScanning = true
        lastScan = now()
        let environment = ImportEnvironment.live { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        let variables = ProcessInfo.processInfo.environment
        Task { [weak self] in
            let imported = await host.importedProfiles()
            let classic = await ClassicWorkspaceCount().count()
            let found = await Task.detached(priority: .utility) {
                ImportScanner(home: environment.homeDirectory, environment: environment, variables: variables,
                              importedProfiles: imported, classicWorkspaces: { classic }).scan()
            }.value
            guard let self else { return }
            findings = found
            isScanning = false
            then?()
        }
    }

    // MARK: Cards

    var deck: ImportCardDeck {
        let apps = Dictionary(findings.compactMap { finding in finding.browser.flatMap { $0.bundleIDs.first }.map { (finding.id, $0) } },
                              uniquingKeysWith: { first, _ in first })
            .merging(Self.agentApps) { first, _ in first }
        return ImportCardDeck(findings: findings, state: state, jobs: ledger, apps: apps)
    }

    /// Bundle ids for the non-browser sources' icons.
    static let agentApps = [
        "agents.claudeCode": "com.anthropic.claudefordesktop", "agents.codex": "com.openai.codex",
        "terminal.iterm2": "com.googlecode.iterm2", "terminal.ghostty": "com.mitchellh.ghostty", "cmux.classic": "com.cmuxterm.app",
    ]

    /// The cards `surface` draws now; empty while the cards are off.
    public func list(for surface: ImportCardDeck.Surface) -> ImportCardList {
        guard isEnabled else { return .empty }
        return deck.list(for: surface, now: now())
    }

    /// Settings › Import's list for the page's host lists (`import_suggestions`), with its empty text; null while the cards are off.
    public var settingsJSON: JSONValue {
        guard isEnabled else { return .null }
        var value = ImportCardJSON.value(list(for: .settings), keepEmpty: true)
        if case .object(var members) = value {
            members["empty"] = .string(ImportSuggestionStrings.settingsEmpty)
            members["scanning"] = .bool(isScanning)
            value = .object(members)
        }
        return value
    }

    /// Pushes the New Tab cards to every agent page on each change of what they show.
    private func follow() {
        withObservationTracking {
            AgentPaneImportCards.shared.cards = ImportCardJSON.value(list(for: .newTab))
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
    }

    // MARK: Buttons

    /// Runs a card's button (a page, the Home strip, `import.card`).
    public func perform(_ id: String, _ action: ImportCardAction) throws {
        switch action {
        case .start: try start(id)
        case .resume, .retry:
            guard var job = ledger.job(id), job.phase != .running else { throw ImportCardsFailure.noSuchCard(id) }
            job.resumed(now: now())
            put(job)
            run(id)
        case .dismiss:
            if state.requests.contains(where: { $0.id == id }) {
                state.drop(request: id)
            } else {
                guard let finding = findings.first(where: { $0.id == id }) else { throw ImportCardsFailure.noSuchCard(id) }
                state.dismiss(finding)
            }
            state.save(to: defaults)
        case .restore:
            state.restore(id)
            state.save(to: defaults)
        case .more:
            _ = registry?.perform("importFromBrowser")
        case .open: open(id)
        case .hide:
            guard ledger.job(id)?.isActive != true else { return }
            ledger.remove(id)
            saveLedger()
        }
    }

    /// The Chief's (or another agent's) request: a card offering `site`'s cookies from `browser`.
    public func raise(browser: ImportBrowser, site: String, reason: String) {
        state.raise(ImportRequest(browser: browser, site: site, reason: reason, requestedAt: now()))
        state.save(to: defaults)
    }

    private func start(_ id: String) throws {
        if let request = state.requests.first(where: { $0.id == id }) {
            // The person's click: Import Cookies from Browser for that site only, as the person.
            let arguments: [String: ActionValue] = [
                "from": .string(request.browser.rawValue), "domain": .string(request.site), "reason": .string(request.reason),
            ]
            _ = registry?.perform("browser.importCookies", invocation: ActionInvocation(arguments: arguments, origin: .user))
            state.drop(request: id)
            state.save(to: defaults)
            return
        }
        guard let finding = findings.first(where: { $0.id == id }) else { throw ImportCardsFailure.noSuchCard(id) }
        guard ledger.job(id)?.isActive != true else { return }
        switch finding.kind {
        case .browser:
            put(ImportJob(finding: finding, now: now()))
            run(id)
        case .claudeCode, .codex:
            // Already indexed device-wide: the card opens them.
            _ = registry?.perform("search.chats")
            finish(ImportJob(finding: finding, now: now()))
        case .cmuxClassic:
            // Its own preview and confirmation; the next scan drops the card once they are here.
            _ = registry?.perform("workspace.importClassic")
        case .iterm2:
            run(id, writingTheme: ImportJob(finding: finding, now: now()))
        case .ghostty:
            open(id)
        }
    }

    private func open(_ id: String) {
        let kind = findings.first { $0.id == id }?.kind ?? ledger.job(id)?.kind
        switch kind {
        case .ghostty: _ = registry?.perform("palette.openGhosttySettings")
        case .claudeCode, .codex: _ = registry?.perform("search.chats")
        case .iterm2: host?.openSettings("#/settings/theme")
        case .browser:
            // Safari behind Full Disk Access: the Privacy pane where cmux is turned on.
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                NSWorkspace.shared.openInBackground(url)
            }
        case .cmuxClassic, nil: break
        }
    }

    /// Settings › Import.
    public func openSettings() { host?.openSettings("#/settings/import") }

    // MARK: Jobs

    private func put(_ job: ImportJob) {
        ledger.put(job)
        saveLedger()
    }

    private func finish(_ job: ImportJob) {
        var job = job
        job.finishedStep(0, counts: ImportCounts(), now: now())
        put(job)
    }

    private func saveLedger() {
        try? ledger.save(to: ledgerURL)
    }

    private func run(_ id: String, writingTheme job: ImportJob) {
        put(job)
        let writer = ITermThemeWriter(home: FileManager.default.homeDirectoryForCurrentUser, variables: ProcessInfo.processInfo.environment)
        Task { [weak self] in
            let written = await Task.detached { try? writer.write() }.value
            guard let self else { return }
            ledger.update(id) { job in
                if written == nil { job.failed(.sourceGone, now: now()) } else { job.finishedStep(0, counts: ImportCounts(), now: now()) }
            }
            saveLedger()
        }
    }

    /// Runs a browser job's steps that are left, one plan per profile, saving after each.
    private func run(_ id: String) {
        guard running[id] == nil, let host, let job = ledger.job(id), job.kind == .browser, let browser = job.browser else { return }
        running[id] = Task { [weak self] in
            await self?.runSteps(id, browser: browser, host: host)
            self?.running[id] = nil
        }
    }

    private func runSteps(_ id: String, browser: ImportBrowser, host: ImportCardsHost) async {
        let access = BrowserFolderAccess()
        // The per-browser folder grant (Debug Settings `browserImport.folderGrant`): asked for once.
        if await access.awaiting().contains(browser), !(await access.request(browser)) {
            return fail(id, .declined)
        }
        guard let source = await access.detect().first(where: { $0.browser == browser }) else { return fail(id, .sourceGone) }
        while let job = ledger.job(id), job.phase == .running, let index = job.nextStep {
            let step = job.steps[index]
            guard let profile = source.profiles.first(where: { $0.directoryName == step.profile }) else {
                ledger.update(id) { $0.finishedStep(index, counts: ImportCounts(), now: now()) }
                saveLedger()
                continue
            }
            let plan = ImportPlan(items: [ImportPlan.Item(profile: profile, kinds: Set(step.kinds))],
                                  mergeTarget: step.intoDefault ? Self.defaultProfile : nil)
            do {
                let summary = plan.items.isEmpty ? ImportSummary(batches: [])
                    : try await host.runImport(plan) { [weak self] progress in
                        guard let self else { return }
                        ledger.update(id) { $0.progressed(progress.fraction, now: now()) }
                    }
                guard summary.failures.isEmpty else { return fail(id, .importFailed) }
                ledger.update(id) { $0.finishedStep(index, counts: summary.counts, now: now()) }
                saveLedger()
            } catch is CancellationError {
                ledger.update(id) { $0.paused(.interrupted, now: now()) }
                return saveLedger()
            } catch {
                return fail(id, .importFailed)
            }
        }
    }

    /// The person's default cmux browser profile (`BrowserProfileRecord.defaultID`).
    static let defaultProfile = "default"

    private func fail(_ id: String, _ reason: ImportJob.Failure) {
        ledger.update(id) { $0.failed(reason, now: now()) }
        saveLedger()
    }
}

/// A refused card button, for `import.card` and the pages.
public nonisolated enum ImportCardsFailure: Error, Equatable, CustomStringConvertible {
    case noSuchCard(String)

    public var description: String {
        switch self {
        case .noSuchCard(let id): ImportSuggestionStrings.noSuchCard(id)
        }
    }
}
