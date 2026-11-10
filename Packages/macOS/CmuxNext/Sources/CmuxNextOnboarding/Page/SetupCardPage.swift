public import AppKit
public import CmuxNextPages
public import CmuxNextSettings
import CmuxNextCompat
import Foundation
public import Observation

/// What the card's rows read and run that only the App has: the account, the `cmux` on the login PATH and
/// their actions. Each runs on the main actor; `account` is read inside observation, so an observable
/// account wakes the card.
@MainActor
public struct SetupCardEnvironment {
    /// Whether this Mac is signed in to a cmux account, and its email.
    public var account: @MainActor () -> (signedIn: Bool, email: String?)
    /// Runs the account sign-in (the person's click).
    public var signInAccount: @MainActor () -> Void
    /// The `cmux` a new login shell runs (``CLIInstallReport/setupRow(_:)``): "installed", "missing", "other" (another
    /// cmux app's: Replace), "fromImage" or "foreign" (no action).
    public var cliState: @MainActor () async -> String
    /// Installs this app's `cmux` (`replacing` another), the person's click; returns once its toast showed.
    public var installCLI: @MainActor (_ replacing: Bool) async -> Void
    /// Opens the Agents window (Chromium), where a VoiceOver press counts as the person's (``SetupCardPageProvider``).
    public var openAgents: @MainActor () -> Void
    /// Whether VoiceOver runs now.
    public var screenReader: @MainActor () -> Bool
    /// Whether this Mac has chats from other agents to bring in (the memory offer's read).
    public var historySources: @MainActor () async -> Bool
    /// Shows Bring your history (the person's click); false when it did not show.
    public var importHistory: @MainActor () -> Bool

    public init(account: @escaping @MainActor () -> (signedIn: Bool, email: String?), signInAccount: @escaping @MainActor () -> Void,
                cliState: @escaping @MainActor () async -> String, installCLI: @escaping @MainActor (_ replacing: Bool) async -> Void,
                openAgents: @escaping @MainActor () -> Void,
                screenReader: @escaping @MainActor () -> Bool = { NSWorkspace.shared.isVoiceOverEnabled },
                historySources: @escaping @MainActor () async -> Bool, importHistory: @escaping @MainActor () -> Bool) {
        self.account = account
        self.signInAccount = signInAccount
        self.cliState = cliState
        self.installCLI = installCLI
        self.openAgents = openAgents
        self.screenReader = screenReader
        self.historySources = historySources
        self.importHistory = importHistory
    }
}

/// One Set Up cmux card's rows and runs (``SetupCardRoute`` makes it while the card shows): `state` (the rows'
/// state as values: the agents from Settings' acpmux sign-ins, the account, the `cmux` on the login PATH);
/// `run {action}` and `hide`, each on the person's own click or key only, one per gesture, as the onboarding
/// page's gestures; `focused` (back from a sign-in: the sign-ins and the PATH are read again).
@MainActor
@Observable
public final class SetupCardPageProvider: PageProvider {
    public nonisolated static let prefix = "cmux.setup."
    /// The agents the card names, in its order: the ones cmux can install.
    static let agentIDs = ["claude", "codex"]

    @ObservationIgnored private let setup: FirstRunSetup
    @ObservationIgnored let agents: AgentsStepModel
    @ObservationIgnored private let environment: SetupCardEnvironment
    /// The `cmux` a new login shell runs, read at start, on focus and after an install; nil before the first read.
    private(set) var cli: String?
    /// Whether this Mac has chats to bring in; nil before the one read.
    private(set) var history: Bool?
    @ObservationIgnored private var historyRead: Task<Void, Never>?
    @ObservationIgnored private var spentGesture: TimeInterval?
    @ObservationIgnored private var cliRead: Task<Void, Never>?
    /// An install of the `cmux` command runs (the row shows its spinner, and another click starts nothing).
    private(set) var cliInstalling = false

    init(setup: FirstRunSetup, agents: (any AgentSignInSource)?, environment: SetupCardEnvironment) {
        self.setup = setup
        self.agents = setup.agents(source: agents)
        self.environment = environment
        self.agents.start()
        readCLI()
        // task-owner: one read of the chat sources at start; stop() cancels it.
        historyRead = Task { [weak self, environment] in
            let found = await environment.historySources()
            guard let self, !Task.isCancelled else { return }
            history = found
        }
    }

    /// The card's own reads end; the shared agents model (``FirstRunSetup/agents(source:)``) and its install go on.
    func stop() {
        cliRead?.cancel()
        historyRead?.cancel()
    }

    private func readCLI() {
        cliRead?.cancel()
        // task-owner: one PATH read; the next read or stop() cancels it.
        cliRead = Task { [weak self, environment] in
            let state = await environment.cliState()
            guard let self, !Task.isCancelled else { return }
            cli = state
        }
    }

    /// The card's state on the wire (setupModel.ts `SetupState`).
    var state: JSONValue {
        let rows: [JSONValue] = Self.agentIDs.compactMap { id in
            guard let agent = agents.agents.first(where: { $0.id == id }) ?? agents.installable.first(where: { $0.id == id }) else { return nil }
            // A read that finds the agent installed wins over an earlier failed install (installed by hand, or
            // found after all): the row then offers its Sign In, not an Install that has nothing to do.
            let state: String = switch agents.installs[id] {
            case .installing: "installing"
            case .failed where !agent.installed: "failed"
            default: !agent.installed ? "missing" : agents.countsAsSignedIn(agent) ? "signedIn"
                : agents.awaitsConfirmation(agent) ? "unverified" : "signedOut"
            }
            return ["id": .string(id), "name": .string(agent.name), "state": .string(state)]
        }
        let account = environment.account()
        var wire: [String: JSONValue] = ["signedIn": .bool(account.signedIn)]
        if account.signedIn, let email = account.email { wire["email"] = .string(email) }
        return ["agents": .array(rows), "history": history == true ? ["done": .bool(setup.historyDone)] : .null,
                "account": .object(wire), "cli": .string(cliInstalling ? "installing" : cli ?? "missing"), "classic": .null]
    }

    /// Every row is done: an agent signed in, the chat history answered (when found: never before the read of
    /// the chat sources returned, so a slow read cannot lose the row), the account signed in, this app's `cmux` on PATH.
    var allDone: Bool {
        agents.agents.contains { Self.agentIDs.contains($0.id) && agents.countsAsSignedIn($0) } && rowsBesideAgentsDone
    }

    /// The rows besides the agents' are done (``allDone``).
    var rowsBesideAgentsDone: Bool {
        (history == false || setup.historyDone) && environment.account().signedIn && cli == "installed"
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case "cmux.setup.state": return state
        case "cmux.setup.focused":
            agents.refresh(recheck: true)
            readCLI()
            return [:]
        default: break
        }
        guard context.userGesture, let event = context.gestureEvent, event != spentGesture else {
            // A VoiceOver press reaches a WebKit page with no click or key; it counts once its trusted click is seen
            // (`PageAccessibilityPress`, manaflow-ai/cmux#37809). A press that still has no gesture with VoiceOver on
            // opens the Agents window from a row, a Chromium page where the same press counts
            // (`ChromiumAccessibilityPress`), and Hide only takes the card away.
            if environment.screenReader(), !context.userGesture {
                switch op {
                case "cmux.setup.run": environment.openAgents()
                case "cmux.setup.hide": setup.end()
                default: throw PageError.unknownOp(op)
                }
                return [:]
            }
            throw PageError(code: PageNativeOp.userOnlyCode, message: "\(op) runs only on its own click or key in Home")
        }
        spentGesture = event
        switch op {
        case "cmux.setup.hide": setup.end()
        case "cmux.setup.run": try run(params["action"] ?? .null)
        default: throw PageError.unknownOp(op)
        }
        return [:]
    }

    private func run(_ action: JSONValue) throws {
        let id = action["id"]?.stringValue ?? ""
        switch action["kind"]?.stringValue {
        case "installAgent" where Self.agentIDs.contains(id): agents.install(id)
        case "signInAgent" where Self.agentIDs.contains(id): agents.signIn(id)
        case "confirmAgent" where Self.agentIDs.contains(id): agents.confirmLogin(id)
        case "signInAccount": environment.signInAccount()
        case "importHistory": if environment.importHistory() { setup.historyAnswered() }
        case "declineHistory": setup.historyAnswered()
        case "installCLI":
            // Only the row's own offer: Install when missing, Replace for another cmux app's CLI; never over a
            // `cmux` that is no cmux app's.
            guard !cliInstalling, cli == "missing" || cli == "other" else { throw PageError.invalidParams("nothing to install") }
            let replacing = cli == "other"
            cliInstalling = true
            cliRead?.cancel()
            // task-owner: one install the person asked for, ended by its toast; then the PATH is read again, and the
            // spinner gives way to what that read found (no button flashes back in between).
            Task { [weak self, environment] in
                await environment.installCLI(replacing)
                let state = await environment.cliState()
                guard let self else { return }
                cli = state
                cliInstalling = false
            }
        default: throw PageError.invalidParams("unknown setup action")
        }
    }
}

/// `cmux.setup.*` on Home's Messages page (webviews/src/pages/home-messages/cards/setup/setupHost.ts): the
/// `changed` stream sends the card's whole state while ``FirstRunSetup/shows`` (a first run, until Hide or every
/// row done) and null once it ends; `state` answers the same. The page listens only for a Chief chat and draws
/// the card under its Needs you section. Ported from the native Home's HomeHostView+SetupCard.swift: the card
/// (``SetupCardPageProvider``) is made only while it shows and the page listens, and its reads end with it.
/// Every row done ends the card (``FirstRunSetup/end()``). The other ops go to the card; none runs without it.
@MainActor
@Observable
public final class SetupCardRoute: PageProvider {
    @ObservationIgnored private let setup: FirstRunSetup
    /// Read when the card is made (the native host read it on show).
    @ObservationIgnored private let agents: @MainActor () -> (any AgentSignInSource)?
    @ObservationIgnored private let environment: SetupCardEnvironment
    /// The card while it shows and the page listens.
    private(set) var card: SetupCardPageProvider?
    @ObservationIgnored private var listeners: [UUID: @MainActor (JSONValue) -> Void] = [:]
    @ObservationIgnored private var watch: Task<Void, Never>?

    public init(setup: FirstRunSetup, agents: @escaping @MainActor () -> (any AgentSignInSource)?, environment: SetupCardEnvironment) {
        self.setup = setup
        self.agents = agents
        self.environment = environment
    }

    nonisolated deinit {
        watch?.cancel()
    }

    private struct Snapshot: Sendable, Equatable {
        var shows: Bool
        var state: JSONValue
        var done: Bool
    }

    /// What the page draws: the card's state while it shows (null before the card is made), null once it ended.
    private var snapshot: Snapshot {
        guard setup.shows else { return Snapshot(shows: false, state: .null, done: false) }
        guard let card else { return Snapshot(shows: true, state: .null, done: false) }
        return Snapshot(shows: true, state: card.state, done: card.allDone)
    }

    private func makeCard() {
        guard card == nil, setup.shows else { return }
        card = SetupCardPageProvider(setup: setup, agents: agents(), environment: environment)
    }

    private func dropCard() {
        card?.stop()
        card = nil
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        if op == SetupCardPageProvider.prefix + "state" { return snapshot.state }
        guard let card, setup.shows else { throw PageError.invalidParams("the Set Up cmux card is not shown") }
        return try await card.call(op, params: params, context: context)
    }

    public func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                          onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == SetupCardPageProvider.prefix + "changed" else { throw PageError.unknownOp(stream) }
        let key = UUID()
        listeners[key] = onEvent
        makeCard()
        if watch == nil { start() }
        return PageSubscription { [weak self] in
            guard let self else { return }
            listeners[key] = nil
            if listeners.isEmpty { pageDidClose() }
        }
    }

    public func pageDidClose() {
        listeners = [:]
        watch?.cancel()
        watch = nil
        dropCard()
    }

    private func start() {
        // task-owner: lives while the page listens to `changed` (cancelled with its last listener or the page);
        // event-driven (Observation of FirstRunSetup and the card).
        watch = Task { [weak self] in
            for await snapshot in ObservationStream({ [weak self] in self?.snapshot }) {
                guard !Task.isCancelled, let self, let snapshot else { return }
                if snapshot.shows, card == nil {
                    makeCard() // shown again: the next value carries the new card's state
                    continue
                }
                if !snapshot.shows, card != nil { dropCard() }
                if snapshot.done { setup.end() }
                for listener in listeners.values { listener(snapshot.state) }
            }
        }
    }
}
