public import AppKit
public import CmuxNextPages
public import CmuxNextSettings
import CmuxNextCompat
import Foundation
import WebKit
public import Observation

extension PageDescriptor {
    /// Home's Set Up cmux card (webviews/src/pages/setup-card, the React card home-messages/cards/setup), shown
    /// in the native Home's Chief chat (``SetupCardHost``).
    public static let setupCard = PageDescriptor(
        id: "cmux.setup-card", resource: "setup-card", namespaces: [SetupCardPageProvider.prefix],
        acceptsFirstMouse: true, followsChatZoom: true)
}

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

/// The Set Up cmux card in the native Home: its page view, sized to the card, and its provider. The
/// React Home draws the same component itself, so this host goes with the native transcript.
@MainActor
public final class SetupCardHost {
    public let page: PageWebView
    public let provider: SetupCardPageProvider
    /// The card's height in points at the page's zoom; 0 before the page measured it.
    public private(set) var height: CGFloat = 0
    /// Called after each height change.
    public var onHeightChange: (() -> Void)?

    public init?(setup: FirstRunSetup, agents: (any AgentSignInSource)?, environment: SetupCardEnvironment,
                 overlayProcess: PageOverlayProcess?) {
        let provider = SetupCardPageProvider(setup: setup, agents: agents, environment: environment)
        // The card floats on the chat's backdrop: a Chromium page cannot be transparent.
        guard let page = PageWebView(descriptor: .setupCard, routes: [PageRoute(prefix: SetupCardPageProvider.prefix, provider: provider)],
                                     options: PageEngineOptions(requiresWebKit: .transparentOverlay, acceptsFirstMouse: true),
                                     overlayProcess: overlayProcess) else { return nil }
        self.page = page
        self.provider = provider
        provider.onSize = { [weak self] height in
            self?.cssHeight = height
            self?.resize()
        }
        // The page follows interface and chat zoom: its CSS height is drawn at the zoom's scale.
        page.onZoomChange = { [weak self] in self?.resize() }
    }

    /// The page's last measured height in CSS px.
    private var cssHeight: CGFloat = 0

    /// The card's height in points: its CSS height at the page's zoom (as ``WebCardPanel`` sizes its card).
    private func resize() {
        let zoom = page.webKitView.pageZoom * page.webKitView.magnification
        let next = ceil(cssHeight * max(zoom, 0.01))
        guard next != height else { return }
        height = next
        onHeightChange?()
    }

    public func close() {
        provider.stop()
        page.close()
    }
}

/// `cmux.setup.*` (webviews/src/pages/setup-card/ops.ts): `state` and the `changed` stream (the rows' state as
/// values: the agents from Settings' acpmux sign-ins, the account, the `cmux` on the login PATH); `run {action}`
/// and `hide`, each on the person's own click or key only, one per gesture, as the onboarding page's gestures;
/// `size {height}` and `focused` (back from a sign-in: the sign-ins and the PATH are read again). Every row done
/// ends the card (``FirstRunSetup/end()``).
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
    @ObservationIgnored var onSize: ((CGFloat) -> Void)?
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
        case "cmux.setup.size":
            if let height = params["height"]?.doubleValue, height.isFinite, height >= 0 { onSize?(CGFloat(min(height, 2000))) }
            return [:]
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

    private struct Snapshot: Sendable, Equatable {
        var state: JSONValue
        var done: Bool
    }

    public func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                          onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == "cmux.setup.changed" else { throw PageError.unknownOp(stream) }
        // task-owner: one per page subscription; its PageSubscription cancels it.
        let task = Task { [weak self] in
            for await snapshot in ObservationStream({ [weak self] in self.map { Snapshot(state: $0.state, done: $0.allDone) } }) {
                guard !Task.isCancelled, let self, let snapshot else { return }
                if snapshot.done { setup.end() }
                onEvent(snapshot.state)
            }
        }
        return PageSubscription { task.cancel() }
    }
}
