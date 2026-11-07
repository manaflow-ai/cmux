import AppKit
import CmuxHomeCore
import CmuxNextActions
import CmuxNextChiefMemory
import CmuxNextCompat
import CmuxNextHomeEngine
import CmuxNextHomeModel
import CmuxNextPages
import CmuxNextSettings
import CmuxNextSidebar

/// The Messages page's first run (`cmux.home.messages.firstRun*`, detail/detailHost.ts): what an
/// empty Chief chat shows, from the app's mirrors, and the runs of its rows. Moved from the native
/// `HomeHostView`, unchanged: the same actions, the same once-only memory offer and intros, and the
/// same welcome played in the chat itself (``ChiefWelcomePlayer``).
///
/// - stream `firstRun`: `{introKind?, memoryOffer?, shortcuts: {terminal?, agent?}, agents: [{id,
///   title, icon, status}], switchKeys?, starters: {workspaces, working, failures, pullRequests}}`
///   for the conversation the page shows; read only while that is a Chief chat with no message yet,
///   so tab changes never wake a Chief with history.
/// - `firstRun.action {action}`: `openTerminal`, `startAgent`, `togglePet`, `importMemories`.
/// - `firstRun.openAgent {id}`, `firstRun.hideSwitchKeys {}`, `firstRun.openKeyboardSettings {}`,
///   `firstRun.markIntroShown {kind, conversation}` (each a click only, but the last).
@MainActor
final class HomeMessagesFirstRunProvider: PageProvider {
    static let prefix = HomeMessagesPageRoute.prefix + "firstRun"
    /// UserDefaults: the first-run memory offer was clicked (it shows once).
    static let memoryOfferUsedKey = "home.firstRun.memoryOfferUsed"
    static let openTerminalAction: ActionID = "newSurface"
    static let startAgentAction: ActionID = "palette.newAgentChat"

    private weak var services: AppServices?
    /// The conversation the page shows (``HomeMessagesHostProvider/shown``).
    private let shown: @MainActor () -> ConversationID?
    private var listeners: [UUID: @MainActor (JSONValue) -> Void] = [:]
    private var watch: Task<Void, Never>?
    /// The memory offer's title, read once off the main actor (nil: nothing found, or used).
    private var memoryOffer: String?
    private var memoryRead: Task<Void, Never>?
    private let intro = ChiefIntroStore(defaults: .standard)

    init(services: AppServices, shown: @escaping @MainActor () -> ConversationID?) {
        self.services = services
        self.shown = shown
    }

    nonisolated deinit {
        watch?.cancel()
        memoryRead?.cancel()
    }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard let services else { throw PageError.unavailable("cmux is closing") }
        let fields = params.objectValue ?? [:]
        let registry = services.registry
        switch op {
        case Self.prefix + ".markIntroShown":
            guard let id = fields["conversation"]?.stringValue, let kind = fields["kind"]?.stringValue.flatMap(ChiefIntroKind.init(rawValue:)) else {
                throw PageError.invalidParams("kind and conversation must name an intro")
            }
            intro.markShown(kind, for: ConversationID(id))
            return .null
        default:
            break
        }
        guard context.userGesture else { throw PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage) }
        switch op {
        case Self.prefix + ".action":
            let id: ActionID
            switch fields["action"]?.stringValue {
            case "openTerminal": id = Self.openTerminalAction
            case "startAgent": id = Self.startAgentAction
            case "togglePet": id = "home.toggleChiefPet"
            case "importMemories":
                id = ChiefMemoryImportHandlers.actionID
                // The offer is used up by the click: the panel shows it once.
                UserDefaults.standard.set(true, forKey: Self.memoryOfferUsedKey)
                memoryOffer = nil
                publish()
            default: throw PageError.invalidParams("action must be openTerminal, startAgent, togglePet or importMemories")
            }
            _ = registry.perform(id, invocation: ActionInvocation(origin: .user))
            return .null
        case Self.prefix + ".openAgent":
            guard let id = fields["id"]?.stringValue, !id.isEmpty else { throw PageError.invalidParams("id must name a tab") }
            _ = services.revealTab(id)
            return .null
        case Self.prefix + ".hideSwitchKeys":
            services.homeSwitchKeys.hide()
            return .null
        case Self.prefix + ".openKeyboardSettings":
            if let url = HomeSwitchKeysSource.keyboardShortcutsURL { NSWorkspace.shared.openInBackground(url) }
            return .null
        default:
            throw PageError.unknownOp(op)
        }
    }

    func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == Self.prefix else { throw PageError.unknownOp(stream) }
        let key = UUID()
        listeners[key] = onEvent
        readMemoryOffer()
        restart()
        return PageSubscription { [weak self] in
            guard let self else { return }
            listeners[key] = nil
            if listeners.isEmpty { watch?.cancel(); watch = nil }
        }
    }

    /// The page shows another conversation: the facts follow it.
    func restart() {
        watch?.cancel()
        watch = nil
        guard !listeners.isEmpty else { return }
        // task-owner: lives while the page listens to `firstRun` (restarted on a new conversation, cancelled with its last listener); event-driven (Observation)
        watch = Task { [weak self] in
            guard let self else { return }
            for await value in ObservationStream({ [weak self] in self?.facts() ?? .null }) {
                let shown = welcome(value)
                for listener in listeners.values { listener(shown) }
            }
        }
    }

    private func publish() {
        let value = welcome(facts())
        for listener in listeners.values { listener(value) }
    }

    /// The shown Chief chat with no message yet, or nil.
    private func emptyChief() -> (ConversationID, HomeService)? {
        guard let home = services?.home, let id = shown(),
              let summary = home.homeStore.rows.first(where: { $0.summary.id == id })?.summary,
              summary.lastSeq == 0, summary.participants.contains(where: { $0.agentClass == .chief }) else { return nil }
        return (id, home)
    }

    private func facts() -> JSONValue {
        guard let services, let (id, home) = emptyChief() else { return .object([:]) }
        let registry = services.registry
        var fields: [String: JSONValue] = [:]
        if let kind = introKind(id, home: home) { fields["introKind"] = .string(kind.rawValue) }
        if let memoryOffer, !home.isCloudConversation(id) { fields["memoryOffer"] = .string(memoryOffer) }
        var shortcuts: [String: JSONValue] = [:]
        if let terminal = registry.shortcutDisplay(for: Self.openTerminalAction) { shortcuts["terminal"] = .string(terminal) }
        if let agent = registry.shortcutDisplay(for: Self.startAgentAction) { shortcuts["agent"] = .string(agent) }
        fields["shortcuts"] = .object(shortcuts)
        let glances = HomeAgentGlances(services: services)
        let agents = glances.current
        fields["agents"] = .array(agents.map { agent in
            .object(["id": .string(agent.id), "title": .string(agent.title), "icon": .string(agent.icon.rawValue),
                     "status": .string(Self.status(agent.status))])
        })
        if let keys = services.homeSwitchKeys.keys(registry: registry) {
            var switching: [String: JSONValue] = ["desktopConflict": .bool(keys.desktopConflict)]
            for (name, value) in [("tabByNumber", keys.tabByNumber), ("workspaceByNumber", keys.workspaceByNumber),
                                  ("nextPreviousTab", keys.nextPreviousTab), ("nextPreviousWorkspace", keys.nextPreviousWorkspace),
                                  ("focusBackForward", keys.focusBackForward)] {
                if let value { switching[name] = .string(value) }
            }
            fields["switchKeys"] = .object(switching)
        }
        let starters = glances.starters(agents: agents, badges: SidebarSessionTree.shared.pullRequests)
        fields["starters"] = .object(starters.mapValues { .array($0.map(JSONValue.string)) })
        return .object(fields)
    }

    /// The Chief's first-open message (``ChiefIntroStore``): the only Chief welcomes once per install;
    /// a Chief made beside others asks what to focus on, once per Chief.
    private func introKind(_ id: ConversationID, home: HomeService) -> ChiefIntroKind? {
        let others = HomeArchivedChiefs(home.directory.archivedChiefs, me: home.homeStore.me?.id).visible(home.homeStore.rows)
            .filter { $0.kind == .chief && $0.id != id }.count
        return intro.intro(for: id, otherChiefs: others)
    }

    /// The welcome plays in the chat itself (its typing dots, then its messages, ``ChiefWelcomePlayer``)
    /// instead of the panel's intro; a cloud Chief, or an owner not connected yet, keeps the intro.
    /// Run outside the observation, once per value, as the native view did.
    private func welcome(_ value: JSONValue) -> JSONValue {
        guard case .object(var fields) = value, fields["introKind"]?.stringValue == ChiefIntroKind.welcome.rawValue,
              let services, let (id, home) = emptyChief(), !home.isCloudConversation(id),
              home.chiefWelcome.play(in: id, source: home.homeSource, connection: home.chief.connection, intro: intro,
                                     text: ChiefWelcome.text(services.registry)) else { return value }
        fields["introKind"] = nil
        return .object(fields)
    }

    /// Onboarding: the Chief's front page offers to bring memory from the other tools found on this
    /// Mac. One read off the main thread; nothing found, nothing shown, and a used offer never returns.
    private func readMemoryOffer() {
        guard memoryRead == nil, let services, !UserDefaults.standard.bool(forKey: Self.memoryOfferUsedKey) else { return }
        let muxHome = HomeBrainHost.muxHome(tag: services.environment.tag).path
        // task-owner: one detection read; ends with it (cancelled in deinit)
        memoryRead = Task { [weak self] in
            let sources = await ChiefMemoryImportHandlers.detectForOffer(muxHome: muxHome)
            guard let self, !Task.isCancelled, let title = MemorySource.offerTitle(sources) else { return }
            memoryOffer = title
            publish()
        }
    }

    private static func status(_ status: HomeAgentGlance.Status) -> String {
        switch status {
        case .needsYou: "needsYou"
        case .failed: "failed"
        case .done: "done"
        case .idle: "idle"
        case .working: "working"
        }
    }
}
