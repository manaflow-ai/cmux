import AppKit
import CmuxChief
import CmuxHomeCore
import Foundation
import Observation

/// The app's local Chief: one ``ChiefConversationOwner`` for this build's
/// Chief home, the ``HomeStore`` every Chief view reads, and the brain chosen
/// by the `chief.*` settings.
///
/// Starts lazily on the first read of ``store`` (Home or a Chief tab
/// opening). A settings change installs a new brain for the next turn; a
/// running turn finishes on the brain it started with.
@MainActor
@Observable
final class ChiefService {
    static let shared = ChiefService()

    /// The store, nil before the first start or when the Chief home could
    /// not be opened (``startFailure`` says why).
    private(set) var storeIfStarted: HomeStore?
    /// Why the Chief could not start, nil when it runs or has not started.
    private(set) var startFailure: String?
    /// The conversations whose Chief is working now.
    private(set) var workingConversations: Set<ConversationID> = []

    @ObservationIgnored private(set) var owner: ChiefConversationOwner?
    @ObservationIgnored private(set) var home: ChiefHome?
    @ObservationIgnored private var brainSwitch: ChiefBrainSwitch?
    @ObservationIgnored private var engine = ChiefSettingsAccess().current
    @ObservationIgnored private var settingsObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var quitObserver: (any NSObjectProtocol)?
    // task-owner: lives as long as the owner; ends when its stream ends (shutdown)
    @ObservationIgnored private var workingWatch: Task<Void, Never>?
    @ObservationIgnored private var started = false

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

    /// Unread Chief messages across every conversation (the Home badge).
    var unreadCount: Int { conversations.reduce(0) { $0 + $1.unread } }

    /// Whether `conversation`'s Chief is running a turn.
    func isWorking(_ conversation: ConversationID) -> Bool {
        workingConversations.contains(conversation)
    }

    /// The Chief home's files (memory, profile).
    var memoryPaths: ChiefMemoryPaths? { home.map(ChiefMemoryPaths.init(home:)) }

    // MARK: Lifecycle

    /// Opens the Chief home and starts the store. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        let home = ChiefHome.resolve()
        let settings = ChiefSettingsAccess().current
        engine = settings
        let switcher = ChiefBrainSwitch(brain: Self.makeBrain(settings), settings: settings)
        let builder = ChiefTurnContextBuilder(engine: { await switcher.settings })
        do {
            let owner = try ChiefConversationOwner(home: home, brain: ChiefSwitchingBrain(switcher: switcher),
                                                   context: { input in await builder.context(for: input) })
            let store = HomeStore(source: ChiefLocalSource(owner: owner),
                                  blobCacheDirectory: home.stateDirectory.appendingPathComponent("blob-cache", isDirectory: true))
            store.start()
            self.home = home
            self.owner = owner
            self.brainSwitch = switcher
            self.storeIfStarted = store
            watchWorking(owner)
            observeSettings()
            observeQuit()
        } catch {
            startFailure = ChiefStrings.unavailable
            NSLog("chief: start failed: %@", String(describing: error))
        }
    }

    /// Stops `conversation`'s running turn. Returns whether one was stopped.
    @discardableResult
    func stop(_ conversation: ConversationID) async -> Bool {
        guard let owner else { return false }
        return await owner.stopTurn(conversation: conversation)
    }

    /// Starts a new conversation with a new Chief and returns its id.
    ///
    /// - Throws: ``HomeRejection`` when the owner refuses.
    func createConversation() async throws -> ConversationID {
        guard let store else { throw HomeRejection.ownerUnreachable }
        let result = try await store.perform(.createChief(name: ChiefStrings.chiefName))
        guard let id = result.conversation else { throw HomeRejection.indeterminate }
        return id
    }

    /// Ends every turn and the brain's processes (app quit).
    func shutdown() async {
        storeIfStarted?.stop()
        await owner?.shutdown()
    }

    // MARK: Brain

    static func makeBrain(_ settings: ChiefEngineSettings) -> any ChiefBrain {
        ChiefBrainFactory.make(harness: settings.resolvedHarness, model: settings.model, effort: settings.effort)
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
        let brain = Self.makeBrain(settings)
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
                if self.workingConversations != set { self.workingConversations = set }
            }
        }
    }
}
