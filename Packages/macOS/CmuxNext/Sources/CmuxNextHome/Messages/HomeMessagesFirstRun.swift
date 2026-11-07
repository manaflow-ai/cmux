public import CmuxHomeCore
import CmuxNextCompat
public import CmuxNextHomeModel
public import CmuxNextPages
public import CmuxNextSettings
import Foundation

/// What the first run reads and runs that only the App has (its mirrors, the action registry, the
/// Chief's welcome): ``HomeMessagesFirstRunProvider`` asks these and keeps everything else.
@MainActor
public struct HomeFirstRunSources {
    /// The Home store (the shown conversation's row).
    public var store: () -> HomeStore?
    /// A Cloud Chief's conversation (no memory offer, no local welcome).
    public var isCloud: (ConversationID) -> Bool
    /// The other visible Chiefs beside this one (the intro asks what to focus on).
    public var otherChiefs: (ConversationID) -> Int
    /// The user's agents (agent chat tabs, hooked terminals), in the mirror's order.
    public var agents: () -> [HomeAgentGlance]
    /// The starter facts: `workspaces`, `working`, `failures`, `pullRequests`.
    public var starters: ([HomeAgentGlance]) -> [String: [String]]
    public var switchKeys: () -> HomeSwitchKeys?
    /// An action's shortcut as the menus show it.
    public var shortcut: (String) -> String?
    /// Runs an action through the registry, as the person's own.
    public var perform: (String) -> Void
    public var openAgent: (String) -> Void
    public var hideSwitchKeys: () -> Void
    public var openKeyboardSettings: () -> Void
    /// Plays the welcome in the chat itself (``ChiefWelcomePlayer``); true when it plays.
    public var playWelcome: (ConversationID) -> Bool
    /// The memory offer's title, read once off the main thread; nil: nothing found.
    public var memoryOffer: () async -> String?
    /// The refusal a page's own call (not a click) gets.
    public var personOnlyMessage: String

    public init(store: @escaping () -> HomeStore?, isCloud: @escaping (ConversationID) -> Bool,
                otherChiefs: @escaping (ConversationID) -> Int, agents: @escaping () -> [HomeAgentGlance],
                starters: @escaping ([HomeAgentGlance]) -> [String: [String]], switchKeys: @escaping () -> HomeSwitchKeys?,
                shortcut: @escaping (String) -> String?, perform: @escaping (String) -> Void,
                openAgent: @escaping (String) -> Void, hideSwitchKeys: @escaping () -> Void,
                openKeyboardSettings: @escaping () -> Void, playWelcome: @escaping (ConversationID) -> Bool,
                memoryOffer: @escaping () async -> String?, personOnlyMessage: String) {
        (self.store, self.isCloud, self.otherChiefs, self.agents, self.starters, self.switchKeys) = (store, isCloud, otherChiefs, agents, starters, switchKeys)
        (self.shortcut, self.perform, self.openAgent, self.hideSwitchKeys) = (shortcut, perform, openAgent, hideSwitchKeys)
        (self.openKeyboardSettings, self.playWelcome, self.memoryOffer, self.personOnlyMessage) = (openKeyboardSettings, playWelcome, memoryOffer, personOnlyMessage)
    }
}

/// The Messages page's first run (`cmux.home.messages.firstRun*`, detail/detailHost.ts): what an
/// empty Chief chat shows, from the app's mirrors, and the runs of its rows. Moved from the native
/// `HomeHostView`, unchanged: the same actions, the same once-only memory offer and intros, and the
/// same welcome played in the chat itself (``ChiefWelcomePlayer``). The App hands it
/// ``HomeFirstRunSources``; the stream, the wire and the click check live here.
///
/// - stream `firstRun`: `{introKind?, memoryOffer?, shortcuts: {terminal?, agent?}, agents: [{id,
///   title, icon, status}], switchKeys?, starters: {workspaces, working, failures, pullRequests}}`
///   for the conversation the page shows; read only while that is a Chief chat with no message yet,
///   so tab changes never wake a Chief with history.
/// - `firstRun.action {action}`: `openTerminal`, `startAgent`, `togglePet`, `importMemories`.
/// - `firstRun.openAgent {id}`, `firstRun.hideSwitchKeys {}`, `firstRun.openKeyboardSettings {}`,
///   `firstRun.markIntroShown {kind, conversation}` (each a click only, but the last).
@MainActor
public final class HomeMessagesFirstRunProvider: PageProvider {
    public static let prefix = HomeMessagesPageRoute.prefix + "firstRun"
    /// UserDefaults: the first-run memory offer was clicked (it shows once).
    public static let memoryOfferUsedKey = "home.firstRun.memoryOfferUsed"
    public static let openTerminalAction = "newSurface"
    public static let startAgentAction = "palette.newAgentChat"
    public static let togglePetAction = "home.toggleChiefPet"
    public static let importMemoriesAction = "chief.importMemories"

    private let sources: HomeFirstRunSources
    /// The conversation the page shows (``HomeMessagesHostProvider/shown``).
    private let shown: @MainActor () -> ConversationID?
    private var listeners: [UUID: @MainActor (JSONValue) -> Void] = [:]
    private var watch: Task<Void, Never>?
    /// The memory offer's title, read once off the main actor (nil: nothing found, or used).
    private var memoryOffer: String?
    private var memoryRead: Task<Void, Never>?
    private let intro = ChiefIntroStore(defaults: .standard)

    public init(sources: HomeFirstRunSources, shown: @escaping @MainActor () -> ConversationID?) {
        self.sources = sources
        self.shown = shown
    }

    nonisolated deinit {
        watch?.cancel()
        memoryRead?.cancel()
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        let fields = params.objectValue ?? [:]
        if op == Self.prefix + ".markIntroShown" {
            guard let id = fields["conversation"]?.stringValue, let kind = fields["kind"]?.stringValue.flatMap(ChiefIntroKind.init(rawValue:)) else {
                throw PageError.invalidParams("kind and conversation must name an intro")
            }
            intro.markShown(kind, for: ConversationID(id))
            return .null
        }
        guard context.userGesture else { throw PageError(code: PageNativeOp.userOnlyCode, message: sources.personOnlyMessage) }
        switch op {
        case Self.prefix + ".action":
            let id: String
            switch fields["action"]?.stringValue {
            case "openTerminal": id = Self.openTerminalAction
            case "startAgent": id = Self.startAgentAction
            case "togglePet": id = Self.togglePetAction
            case "importMemories":
                id = Self.importMemoriesAction
                // The offer is used up by the click: the panel shows it once.
                UserDefaults.standard.set(true, forKey: Self.memoryOfferUsedKey)
                memoryOffer = nil
                publish()
            default: throw PageError.invalidParams("action must be openTerminal, startAgent, togglePet or importMemories")
            }
            sources.perform(id)
            return .null
        case Self.prefix + ".openAgent":
            guard let id = fields["id"]?.stringValue, !id.isEmpty else { throw PageError.invalidParams("id must name a tab") }
            sources.openAgent(id)
            return .null
        case Self.prefix + ".hideSwitchKeys":
            sources.hideSwitchKeys()
            return .null
        case Self.prefix + ".openKeyboardSettings":
            sources.openKeyboardSettings()
            return .null
        default:
            throw PageError.unknownOp(op)
        }
    }

    public func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
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
    public func restart() {
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
    private func emptyChief() -> ConversationID? {
        guard let store = sources.store(), let id = shown(),
              let summary = store.rows.first(where: { $0.summary.id == id })?.summary,
              summary.lastSeq == 0, summary.participants.contains(where: { $0.agentClass == .chief }) else { return nil }
        return id
    }

    private func facts() -> JSONValue {
        guard let id = emptyChief() else { return .object([:]) }
        var fields: [String: JSONValue] = [:]
        if let kind = intro.intro(for: id, otherChiefs: sources.otherChiefs(id)) { fields["introKind"] = .string(kind.rawValue) }
        if let memoryOffer, !sources.isCloud(id) { fields["memoryOffer"] = .string(memoryOffer) }
        var shortcuts: [String: JSONValue] = [:]
        if let terminal = sources.shortcut(Self.openTerminalAction) { shortcuts["terminal"] = .string(terminal) }
        if let agent = sources.shortcut(Self.startAgentAction) { shortcuts["agent"] = .string(agent) }
        fields["shortcuts"] = .object(shortcuts)
        let agents = sources.agents()
        fields["agents"] = .array(agents.map { agent in
            .object(["id": .string(agent.id), "title": .string(agent.title), "icon": .string(agent.icon.rawValue),
                     "status": .string(Self.status(agent.status))])
        })
        if let keys = sources.switchKeys() {
            var switching: [String: JSONValue] = ["desktopConflict": .bool(keys.desktopConflict)]
            for (name, value) in [("tabByNumber", keys.tabByNumber), ("workspaceByNumber", keys.workspaceByNumber),
                                  ("nextPreviousTab", keys.nextPreviousTab), ("nextPreviousWorkspace", keys.nextPreviousWorkspace),
                                  ("focusBackForward", keys.focusBackForward)] {
                if let value { switching[name] = .string(value) }
            }
            fields["switchKeys"] = .object(switching)
        }
        fields["starters"] = .object(sources.starters(agents).mapValues { .array($0.map(JSONValue.string)) })
        return .object(fields)
    }

    /// The welcome plays in the chat itself (its typing dots, then its messages, ``ChiefWelcomePlayer``)
    /// instead of the panel's intro; a cloud Chief, or an owner not connected yet, keeps the intro.
    /// Run outside the observation, once per value, as the native view did.
    private func welcome(_ value: JSONValue) -> JSONValue {
        guard case .object(var fields) = value, fields["introKind"]?.stringValue == ChiefIntroKind.welcome.rawValue,
              let id = emptyChief(), !sources.isCloud(id), sources.playWelcome(id) else { return value }
        fields["introKind"] = nil
        return .object(fields)
    }

    /// Onboarding: the Chief's front page offers to bring memory from the other tools found on this
    /// Mac. One read off the main thread; nothing found, nothing shown, and a used offer never returns.
    private func readMemoryOffer() {
        guard memoryRead == nil, !UserDefaults.standard.bool(forKey: Self.memoryOfferUsedKey) else { return }
        let read = sources.memoryOffer
        // task-owner: one detection read; ends with it (cancelled in deinit)
        memoryRead = Task { [weak self] in
            let title = await read()
            guard let self, !Task.isCancelled, let title else { return }
            memoryOffer = title
            publish()
        }
    }

    static func status(_ status: HomeAgentGlance.Status) -> String {
        switch status {
        case .needsYou: "needsYou"
        case .failed: "failed"
        case .done: "done"
        case .idle: "idle"
        case .working: "working"
        }
    }
}
