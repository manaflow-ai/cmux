public import AppKit
public import CmuxNextActions
public import CmuxNextBrowserImport
import CmuxNextCompat
import CmuxNextDesign
public import CmuxNextImportSuggestions
import CmuxNextOnboarding
public import CmuxNextSettings
import Observation

/// The import suggestion cards for the whole app: it scans this Mac off the
/// main thread at launch and when cmux comes forward again (at most every
/// ``rescanInterval``), keeps the person's dismissals and the Chief's
/// requests, and runs each card's import as a job saved after every step, so
/// a quit or crash leaves it paused for Resume (or resumes it at launch when
/// no prompt is left). Settings › Import draws what ``list()`` returns; Home and
/// New Tab show no suggestion (Leo 2026-10-21: "yes to both", removing it from both).
@MainActor
@Observable
public final class ImportSuggestionsCenter {
    public static let shared = ImportSuggestionsCenter()

    /// Every source the last scan found.
    public private(set) var findings: [ImportFinding] = []
    public private(set) var state: ImportSuggestionState
    public internal(set) var ledger = ImportJobLedger()
    /// A scan is running.
    public private(set) var isScanning = false
    /// The cards' source app icons, rendered off the main thread when a scan lands.
    let icons = ImportAppIconCache()

    /// cmux comes forward this long after the last scan before the next one.
    public static let rescanInterval: TimeInterval = 10 * 60

    @ObservationIgnored var host: ImportCardsHost?
    /// What a scan finds on this Mac (a test's fixed findings).
    @ObservationIgnored var scanThisMac: @MainActor (ImportCardsHost) async -> [ImportFinding] = ImportSuggestionsCenter.scanLive
    @ObservationIgnored private weak var registry: ActionRegistry?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let ledgerURL: URL
    @ObservationIgnored private var lastScan: Date?
    /// The scan in flight, cancelled when `browser.import.enabled` turns off.
    @ObservationIgnored private var scanning: Task<Void, Never>?
    /// Bumped when a scan in flight is dropped, so its late answer changes nothing.
    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored var running: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var activation: (any NSObjectProtocol)?
    @ObservationIgnored private var started = false
    /// A page's start is waiting on the person's answer (one question at a time).
    @ObservationIgnored private var asking = false
    @ObservationIgnored let now: () -> Date

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

    /// `browser.import.enabled` (on by default): off, no card shows and nothing scans or resumes.
    /// Turned on again, the cards scan this Mac.
    public var importEnabled = true {
        didSet {
            if importEnabled, !oldValue, started { scan { [weak self] in self?.resumeInterrupted() } }
            // Off: a scan in flight stops before it reads another browser, and its findings are dropped;
            // on again, the next scan starts at once.
            if !importEnabled, isScanning {
                scanning?.cancel()
                scanning = nil
                scanGeneration += 1
                isScanning = false
            }
        }
    }

    /// `browser.import.enabled` and Debug Settings `browserImport.suggestionCards` (both on by default).
    public var isEnabled: Bool { importEnabled && BrowserImportTunables.suggestionCards.value }

    /// Starts the cards once: the jobs a quit cut off, the first scan and the rescans.
    public func start(host: ImportCardsHost, registry: ActionRegistry) {
        self.host = host
        self.registry = registry
        guard !started else { return }
        started = true
        restoreJobs()
        state.expire(now: now())
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                            queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rescanIfStale() }
        }
        scan { [weak self] in self?.resumeInterrupted() }
    }

    /// A job the quit cut off goes on by itself only when nothing it has left asks the person.
    private func resumeInterrupted() {
        guard isEnabled else { return }
        for job in ledger.jobs where job.phase == .paused && job.pause == .interrupted && job.resumesQuietly {
            try? perform(job.id, .resume)
        }
    }

    /// The jobs saved before this launch: one a quit cut off is paused for Resume.
    func restoreJobs() {
        var loaded = ImportJobLedger.load(from: ledgerURL)
        loaded.relaunched(now: now())
        ledger = loaded
        saveLedger()
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
        let scan = scanThisMac
        let generation = scanGeneration
        // task-owner: ImportSuggestionsCenter.scanning (cancelled when browser import turns off)
        scanning = Task { [weak self] in
            let found = await scan(host)
            // Dropped while it ran (browser import turned off): what it found is not shown.
            guard let self, generation == scanGeneration else { return }
            isScanning = false
            scanning = nil
            guard isEnabled else {
                then?()
                return
            }
            findings = found
            icons.load(deck.list().cards.compactMap(\.app))
            then?()
        }
    }

    /// This Mac's sources, read off the main thread.
    static func scanLive(_ host: ImportCardsHost) async -> [ImportFinding] {
        let environment = ImportEnvironment.live { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        let variables = ProcessInfo.processInfo.environment
        let imported = await host.importedProfiles()
        // Classic's session file is up to 32 MB of JSON: read and planned off the main actor.
        let classic = await Task.detached(priority: .utility) { await ClassicWorkspaceCount().count() }.value
        // Browser import turned off meanwhile: no other browser's data is read. The scan itself
        // runs detached, so the cancel reaches it through `stop`, checked before each source.
        guard !Task.isCancelled else { return [] }
        let stop = ImportScanStop()
        return await withTaskCancellationHandler {
            await Task.detached(priority: .utility) {
                ImportScanner(home: environment.homeDirectory, environment: environment, variables: variables,
                              importedProfiles: imported, classicWorkspaces: { classic }, shouldStop: { stop.isSet }).scan()
            }.value
        } onCancel: {
            stop.set()
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

    /// The cards Settings › Import lists now; empty while the cards are off.
    public func list() -> ImportCardList {
        guard isEnabled else { return .empty }
        return deck.list()
    }

    /// Settings › Import's list for the page's host lists (`import_suggestions`), with its empty text; null while the cards are off.
    public var settingsJSON: JSONValue {
        guard isEnabled else { return .null }
        var value = ImportCardJSON.value(list(), icons: icons, keepEmpty: true)
        if case .object(var members) = value {
            members["empty"] = .string(ImportSuggestionStrings.settingsEmpty)
            members["scanning"] = .bool(isScanning)
            value = .object(members)
        }
        return value
    }

    // MARK: Buttons

    /// Runs a card's button (Settings › Import's page, `import.card`). `caller` is the run that
    /// pressed it, the person's own click when nil. Only that click starts an import at once: any
    /// other caller's Import, Resume or Try Again asks the person in a native dialog first (page
    /// script cannot answer it), and an agent's cookie request always gets
    /// `browser.importCookies`' consent panel. Whatever the card opens runs as `caller`.
    public func perform(_ id: String, _ action: ImportCardAction, caller: ActionInvocation? = nil) throws {
        // Off (`browser.import.enabled`, the Debug toggle): a row or dialog still on screen starts nothing.
        guard isEnabled || action == .dismiss else { throw ImportCardsFailure.noSuchCard(id) }
        if action.startsWork, let caller, caller.origin != .user, let question = try question(id, action) {
            return ask(question, id: id, action: action, caller: caller)
        }
        switch action {
        case .start: try start(id, caller: caller)
        case .resume, .retry:
            guard var job = ledger.job(id), job.phase != .running else { throw ImportCardsFailure.noSuchCard(id) }
            job.resumed(now: now())
            switch job.kind {
            case .browser:
                put(job)
                run(id)
            case .iterm2: run(id, writingTheme: job)
            case .cmuxClassic:
                // Runs the import again; the migration ledger skips what already came over.
                put(job)
                runClassic(id)
            case .claudeCode, .codex, .ghostty: finish(job)
            }
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
            _ = registry?.perform("importFromBrowser", invocation: Self.forwarded(caller))
        case .open: open(id, caller: caller)
        case .hide:
            // Done, or Not Now on a paused or failed job: the card goes, and like a dismissed
            // card it comes back only when the scan finds something new for that source.
            guard ledger.job(id)?.isActive != true else { return }
            ledger.remove(id)
            saveLedger()
            if let finding = findings.first(where: { $0.id == id }) {
                state.dismiss(finding)
                state.save(to: defaults)
            }
        }
    }

    /// The Chief's (or another agent's) request: a card offering `site`'s cookies from `browser`.
    /// `caller` is the run that raised it (`import.suggest`); the import later runs as that caller.
    public func raise(browser: ImportBrowser, site: String, reason: String, caller: ActionInvocation? = nil) {
        state.raise(ImportRequest(browser: browser, site: site, reason: reason, requestedAt: now(), raisedBy: caller?.origin.rawValue,
                                  agentSession: caller?.callerAgentSession, terminal: caller?.callerTerminal))
        state.save(to: defaults)
    }

    // MARK: Asking

    /// What a start that is not the person's own click asks first, nil when it needs no question
    /// (a cookie request: its consent panel asks; a card that only opens something of cmux's).
    /// Throws when there is no such card, so `import.card` still reports it.
    private func question(_ id: String, _ action: ImportCardAction) throws -> CmuxDialogSpec? {
        if action == .start {
            if state.requests.contains(where: { $0.id == id }) { return nil }
            guard findings.contains(where: { $0.id == id }) else { throw ImportCardsFailure.noSuchCard(id) }
            // Already importing: the press does nothing, so there is nothing to ask.
            if ledger.job(id)?.isActive == true { return nil }
        } else {
            guard let job = ledger.job(id), job.phase != .running else { throw ImportCardsFailure.noSuchCard(id) }
        }
        guard let card = deck.cards().first(where: { $0.id == id }), card.kind.startReadsAnotherApp else { return nil }
        let confirm = CmuxDialogButton(id: "confirm", title: ImportSuggestionStrings.confirmButton(action), role: .default)
        return CmuxDialogSpec(title: ImportSuggestionStrings.confirmTitle(card.title), lines: [card.facts, card.benefit].filter { !$0.isEmpty },
                              buttons: [.cancel(), confirm], identifier: "cmux.dialog.importCard")
    }

    /// Shows `question` above the app, then runs the press as the person's own when they confirm.
    /// One question at a time: a press while one is up does nothing, so a page cannot stack them.
    private func ask(_ question: CmuxDialogSpec, id: String, action: ImportCardAction, caller: ActionInvocation) {
        guard !asking else { return }
        asking = true
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        CmuxDialogCenter.shared.present(question, in: window.map { .window($0) } ?? .app) { [weak self] answer in
            guard let self else { return }
            asking = false
            guard answer.button == "confirm" else { return }
            // The person approved it on a native dialog: from here the press is theirs.
            var confirmed = Self.forwarded(caller)
            confirmed.origin = .user
            try? perform(id, action, caller: confirmed)
        }
    }

    /// A run a card's button starts for `caller`, as `caller`: its origin and its own caller claims,
    /// so an agent's or a page's press never becomes the person's own. The person's click when nil.
    nonisolated static func forwarded(_ caller: ActionInvocation?) -> ActionInvocation {
        guard let caller else { return ActionInvocation() }
        var invocation = ActionInvocation(origin: caller.origin, focusRequested: caller.focusRequested)
        invocation.callerApp = caller.callerApp
        invocation.callerAgentSession = caller.callerAgentSession
        invocation.callerTerminal = caller.callerTerminal
        return invocation
    }

    /// The run that imports a request's cookies. An agent's request is the agent's ask whoever
    /// presses Import, so it runs as the agent that raised it (the consent panel names that chat
    /// and the site); a request the person raised runs as whoever pressed it. A request kept
    /// before its raiser was recorded counts as a script's.
    nonisolated static func cookieRun(_ request: ImportRequest, caller: ActionInvocation?) -> ActionInvocation {
        let raised = request.raisedBy.map { ActionOrigin(rawValue: $0) ?? .script } ?? .script
        let origin = raised != .user ? raised : caller?.origin ?? .user
        // The consent panel shows the agent's reason; an agent that gave none still gets a line naming the import.
        let reason = request.reason.isEmpty
            ? ImportSuggestionStrings.requestTitle(browser: request.browser.displayName, site: request.site) : request.reason
        var invocation = ActionInvocation(arguments: [
            "from": .string(request.browser.rawValue), "domain": .string(request.site), "reason": .string(reason),
        ], origin: origin)
        invocation.callerAgentSession = raised != .user ? request.agentSession : caller?.callerAgentSession
        invocation.callerTerminal = raised != .user ? request.terminal : caller?.callerTerminal
        return invocation
    }

    private func start(_ id: String, caller: ActionInvocation?) throws {
        if let request = state.requests.first(where: { $0.id == id }) {
            // Import Cookies from Browser for that site only, as the agent that asked for it.
            _ = registry?.perform("browser.importCookies", invocation: Self.cookieRun(request, caller: caller))
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
            _ = registry?.perform("search.chats", invocation: Self.forwarded(caller))
            finish(ImportJob(finding: finding, now: now()))
        case .cmuxClassic:
            // The action's own import, tracked: its preview asks before anything opens.
            put(ImportJob(finding: finding, now: now()))
            runClassic(id)
        case .iterm2:
            run(id, writingTheme: ImportJob(finding: finding, now: now()))
        case .ghostty:
            open(id, caller: caller)
        }
    }

    private func open(_ id: String, caller: ActionInvocation?) {
        let kind = findings.first { $0.id == id }?.kind ?? ledger.job(id)?.kind
        switch kind {
        case .ghostty: _ = registry?.perform("palette.openGhosttySettings", invocation: Self.forwarded(caller))
        case .claudeCode, .codex: _ = registry?.perform("search.chats", invocation: Self.forwarded(caller))
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
