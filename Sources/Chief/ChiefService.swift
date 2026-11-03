import AppKit
import CmuxChief
import CmuxHomeCore
import Foundation
import Observation
import OSLog

private nonisolated let chiefServiceLog = Logger(subsystem: "com.cmuxterm.app", category: "Chief")

/// The app's local Chief: one ``ChiefConversationOwner`` for this build's
/// Chief home, the ``HomeStore`` every Chief view reads, and the brain chosen
/// by the `chief.*` settings.
///
/// Starts lazily on the first read of ``store`` (Home or a Chief tab
/// opening). Starting never reads conversation files on the main thread:
/// the store exists at once and connects when the owner has loaded them
/// (``ChiefConversationOwner/load(home:brain:userDisplayName:now:context:)``).
/// A settings change installs a new brain for the next turn; a running turn
/// finishes on the brain it started with.
@MainActor
@Observable
final class ChiefService {
    static let shared = ChiefService()

    /// The store, nil before the first start or when the Chief home could
    /// not be opened (``startFailure`` says why). It exists while the owner
    /// still loads; it connects when the owner is ready.
    private(set) var storeIfStarted: HomeStore?
    /// Why the Chief could not start, nil when it runs or has not started.
    private(set) var startFailure: String?
    /// The conversations whose Chief is working now.
    private(set) var workingConversations: Set<ConversationID> = []

    /// The owner, nil until its load ends (``ownerLoad``).
    @ObservationIgnored private(set) var owner: ChiefConversationOwner?
    /// The owner's load, set by ``start()``; it reads the conversation files off the main thread.
    @ObservationIgnored private(set) var ownerLoad: Task<ChiefConversationOwner, any Error>?
    @ObservationIgnored private(set) var home: ChiefHome?
    @ObservationIgnored private var allowRules: ChiefAllowRules?
    /// The home is a fresh temporary folder (a scripted DEBUG run, ``resolveHome()``), not the user's.
    @ObservationIgnored private(set) var homeIsTemporary = false
    @ObservationIgnored private var brainSwitch: ChiefBrainSwitch?
    @ObservationIgnored private var engine = ChiefSettingsAccess().current
    @ObservationIgnored private var settingsObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var quitObserver: (any NSObjectProtocol)?
    // task-owner: lives as long as the owner; ends when its stream ends (shutdown)
    @ObservationIgnored private var workingWatch: Task<Void, Never>?
    /// When each working conversation's turn started (``turnStart(_:)``);
    /// changes only with ``workingConversations``, so Observation tracks that.
    @ObservationIgnored private(set) var turnStarts: [ConversationID: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var started = false
    /// The list's preview lines by conversation (ChiefService+Previews.swift), with the row state
    /// each was read at.
    @ObservationIgnored var previewLines: [ConversationID: ChiefPreviewEntry] = [:]
    /// Conversations whose preview read is in flight.
    @ObservationIgnored var previewReads: Set<ConversationID> = []
    /// Bumped when a preview line lands: the list re-reads its rows (Observation).
    var previewGeneration = 0

    /// The first-run panel's "Open a terminal" and "Start an agent" rows run
    /// this; nil hides the two rows. The app wires it to its own actions.
    @ObservationIgnored var onFirstRunAction: ((ChiefFirstRunAction) -> Void)?
    /// A click on an app link (`cmux://…`) in Chief's text; nil opens it with the system.
    @ObservationIgnored var onAppLink: ((URL) -> Void)?

    private init() {}

    // MARK: Reading

    /// The store of Chief conversations, starting the Chief on first use.
    var store: HomeStore? {
        start()
        return storeIfStarted
    }

    /// The user's participant id in every Chief conversation.
    var me: ParticipantID { ChiefConversationOwner.userID }

    /// The conversation that always exists: the default Chief's.
    var defaultConversationID: ConversationID { ChiefConversationOwner.defaultConversationID }

    /// Every Chief conversation, pinned first, then newest first.
    var conversations: [InboxRow] { storeIfStarted?.rows ?? [] }

    /// Conversations a transcript shows to the user now (key window, page
    /// visible), by the view that shows each.
    private var visibleTranscripts: [ObjectIdentifier: ConversationID] = [:]
    /// Changes when a transcript becomes visible or hidden so Home's list can
    /// clear an unread dot without waiting for a store mutation.
    var visibleGeneration = 0

    /// Conversations the user can see now; their replies are read as they land.
    var visibleConversations: Set<ConversationID> { Set(visibleTranscripts.values) }

    /// Records whether `view` shows `conversation` to the user now (``ChiefTranscriptView``).
    func setTranscript(_ view: AnyObject, showing conversation: ConversationID?) {
        setTranscript(ObjectIdentifier(view), showing: conversation)
    }

    /// ``setTranscript(_:showing:)`` by the view's identity, for a view's
    /// `deinit`, which cannot hand `self` to the main actor.
    func setTranscript(_ key: ObjectIdentifier, showing conversation: ConversationID?) {
        guard visibleTranscripts[key] != conversation else { return }
        visibleTranscripts[key] = conversation
        visibleGeneration &+= 1
    }

    /// Unread Chief messages in the conversations the user cannot see now
    /// (the Home row's dot): a reply on screen is never counted, even
    /// before its read cursor lands.
    var unreadCount: Int {
        let visible = visibleConversations
        return conversations.reduce(0) { $0 + (visible.contains($1.id) ? 0 : $1.unread) }
    }

    /// Whether `conversation`'s Chief is running a turn.
    func isWorking(_ conversation: ConversationID) -> Bool {
        workingConversations.contains(conversation)
    }

    /// The Chief home's files (memory, profile).
    var memoryPaths: ChiefMemoryPaths? { home.map(ChiefMemoryPaths.init(home:)) }

    // MARK: Lifecycle

    /// Opens the Chief home and starts the store. Idempotent, and cheap on
    /// the main thread: the owner loads on a background task and the store
    /// connects when it is ready.
    func start() {
        guard !started else { return }
        started = true
        let (home, temporary) = Self.resolveHome()
        let settings = ChiefSettingsAccess().current
        engine = settings
        let allowRules = ChiefAllowRules()
        let switcher = ChiefBrainSwitch(brain: Self.makeBrain(settings, allowRules: allowRules), settings: settings)
        let builder = ChiefTurnContextBuilder(engine: { await switcher.settings })
        let brain = ChiefSwitchingBrain(switcher: switcher)
        // task-owner: one load of the Chief home; ends when the owner is ready or the load failed
        let loading = Task.detached(priority: .userInitiated) {
            try await ChiefConversationOwner.load(home: home, brain: brain, allowRules: allowRules,
                                                  context: { input in await builder.context(for: input) })
        }
        let store = HomeStore(source: ChiefLocalSource(loading: loading),
                              blobCacheDirectory: home.stateDirectory.appendingPathComponent("blob-cache", isDirectory: true))
        store.start()
        self.home = home
        self.allowRules = allowRules
        self.homeIsTemporary = temporary
        self.brainSwitch = switcher
        self.ownerLoad = loading
        self.storeIfStarted = store
        observeSettings()
        observeQuit()
        // task-owner: waits for the one load above; ends with it
        Task { @MainActor [weak self] in
            do {
                let owner = try await loading.value
                self?.ownerLoaded(owner)
            } catch {
                self?.ownerFailed(error)
            }
        }
    }

    private func ownerLoaded(_ owner: ChiefConversationOwner) {
        self.owner = owner
        for problem in owner.loadProblems { chiefServiceLog.error("load problem: \(problem, privacy: .private)") }
        watchWorking(owner)
    }

    private func ownerFailed(_ error: any Error) {
        startFailure = ChiefStrings.unavailable
        storeIfStarted?.stop()
        storeIfStarted = nil
        chiefServiceLog.error("start failed: \(String(describing: error), privacy: .private)")
    }

    /// Stops `conversation`'s running turn. Returns whether one was stopped.
    @discardableResult
    func stop(_ conversation: ConversationID) async -> Bool {
        guard let owner else { return false }
        return await owner.stopTurn(conversation: conversation)
    }

    /// A failed turn's Try Again: runs the user's last message of `conversation` again.
    /// Returns whether a turn started (false while one runs, or with nothing to resend).
    @discardableResult
    func retryLastTurn(_ conversation: ConversationID) async -> Bool {
        guard let owner else { return false }
        return await owner.retryLastTurn(conversation: conversation)
    }

    /// A memory note was saved while `conversation` shows or works: its transcript row.
    func noteMemorySaved(_ fact: ChiefMemoryFact, in conversation: ConversationID) async {
        guard let owner else { return }
        await owner.noteMemorySaved(conversation: conversation, fact: fact.id, text: fact.text)
    }

    /// A memory row's Undo: forgets the note, then its row says so. Returns whether it was forgotten.
    func undoMemory(_ fact: String, in conversation: ConversationID) async -> Bool {
        guard ChiefMemoryStore.shared.forget(fact) else { return false }
        if let owner { await owner.noteMemoryForgotten(conversation: conversation, fact: fact) }
        return true
    }

    /// Starts a new conversation with a new Chief and returns its id.
    ///
    /// - Throws: ``HomeRejection`` when the owner refuses.
    func createConversation() async throws -> ConversationID {
        guard let store else { throw HomeRejection.ownerUnreachable }
        let result = try await store.perform(.createChief(name: ChiefProfile.currentName()))
        guard let id = result.conversation else { throw HomeRejection.indeterminate }
        return id
    }

    /// Ends every turn and the brain's processes (app quit).
    func shutdown() async {
        storeIfStarted?.stop()
        await owner?.shutdown()
    }

    // MARK: Brain

    static func makeBrain(_ settings: ChiefEngineSettings, allowRules: ChiefAllowRules? = nil) -> any ChiefBrain {
#if DEBUG
        // Dogfood tours and screenshots: a scripted turn, no model or credentials.
        if usesScriptedBrain { return ChiefScriptedBrain(allowRules: allowRules) }
#endif
        return settings.resolvedHarness.makeBrain(model: settings.model, effort: settings.effort,
                                                  dangerouslySkipPermissions: settings.dangerouslySkipPermissions,
                                                  allowRules: allowRules)
    }

#if DEBUG
    /// `CMUX_CHIEF_BRAIN=scripted` (DEBUG builds): every turn runs ``ChiefScriptedBrain``.
    static var usesScriptedBrain: Bool {
        ProcessInfo.processInfo.environment["CMUX_CHIEF_BRAIN"] == "scripted"
    }
#endif

    /// This build's Chief home. A scripted DEBUG run without `CMUX_CHIEF_HOME`
    /// gets a fresh one, so it starts empty and never touches real history.
    /// - Returns: The home, and whether it is that fresh temporary one.
    private static func resolveHome() -> (ChiefHome, temporary: Bool) {
#if DEBUG
        if usesScriptedBrain, ProcessInfo.processInfo.environment[ChiefHome.environmentKey]?.isEmpty ?? true {
            return (ChiefHome(root: FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-chief-scripted-\(UUID().uuidString)", isDirectory: true)), true)
        }
#endif
        return (ChiefHome.resolve(), false)
    }

    /// The settings the brain runs with now (what the settings panel shows).
    var engineSettings: ChiefEngineSettings { engine }

    /// Writes new engine settings; the change applies from the next turn.
    func setEngineSettings(_ settings: ChiefEngineSettings) {
        ChiefSettingsAccess().write(settings)
        applySettingsIfChanged()
    }

    private func applySettingsIfChanged() {
        let settings = ChiefSettingsAccess().current
        guard settings != engine, let brainSwitch else { return }
        engine = settings
        let brain = Self.makeBrain(settings, allowRules: allowRules)
        // task-owner: one swap; ends when the old brain is retired
        Task { await brainSwitch.replace(with: brain, settings: settings) }
    }

    private func observeSettings() {
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettingsIfChanged() } // main-proof: observer on queue: .main
        }
    }

    private func observeQuit() {
        quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // The brain's CLIs are children of the app; terminate them with it.
            MainActor.assumeIsolated { self?.terminateBrainProcesses() } // main-proof: observer on queue: .main
        }
    }

    /// Best effort at quit: the owner's shutdown runs on its actor; the app
    /// does not wait for it.
    private func terminateBrainProcesses() {
        guard let owner else { return }
        // task-owner: app quit; the process may exit before it ends
        Task.detached { await owner.shutdown() }
    }

    private func watchWorking(_ owner: ChiefConversationOwner) {
        workingWatch = Task { [weak self] in
            for await set in await owner.workingConversations() {
                guard let self else { return }
                if self.workingConversations != set {
                    let now = ContinuousClock.now
                    self.turnStarts = Dictionary(uniqueKeysWithValues: set.map { ($0, self.turnStarts[$0] ?? now) })
                    self.workingConversations = set
                }
            }
        }
    }
}
