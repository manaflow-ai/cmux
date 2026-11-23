public import Foundation
public import Observation

/// Whether Home shows the Set Up cmux card (goal next-first-run-setup; Lawrence 2026-10-09: "i do not want new
/// window ... just drop user into main screen asap"). A first run starts it in place of the first-run windows:
/// the Agents window and the CLI toast at launch mark themselves shown, so their rows on the card are the one
/// place they are offered. Hide or every row done ends first-run setup, per channel (`defaults`), and marks this
/// Mac's first launch finished (``OnboardingWindowPresenter/historyShownKey``). An explicit reopen keeps the card
/// visible until Hide.
@MainActor
@Observable
public final class FirstRunSetup {
    /// UserDefaults: "pending" for first run, "reopened" for an explicit visit, "ended" once hidden or done.
    public static let stateKey = "home.firstRun.setupCard"
    /// Whether Home shows the card now.
    public private(set) var shows: Bool
    @ObservationIgnored private let defaults: UserDefaults

    /// `skipsOnboarding` (`--skip-onboarding`, `CMUX_NEXT_SKIP_ONBOARDING=1`): the card stays away for this launch
    /// and starts on none, and a card still pending returns on the next launch that does not skip.
    public init(defaults: UserDefaults = .standard, skipsOnboarding: Bool = false) {
        self.defaults = defaults
        self.skipsOnboarding = skipsOnboarding
        shows = !skipsOnboarding && ["pending", "reopened"].contains(defaults.string(forKey: Self.stateKey) ?? "")
    }

    @ObservationIgnored private let skipsOnboarding: Bool
    /// Observed (not ignored): ``needsChiefAgent`` reads it, so a model made after a reader subscribed wakes it.
    private var agentsModel: AgentsStepModel?

    /// The agent Chief answers through when no route is configured: the person's own Claude Code.
    public static let chiefAgentID = "claude"

    /// Hide on the Chief card: it stays away until the next launch.
    private var chiefAgentHidden = false

    /// Whether Home's Chief chat shows the card's Chief form (first-run findings rows 1 and 4: with onboarding off,
    /// a fresh Mac opened straight into Home and Chief refused every message). True only on evidence that Chief
    /// cannot answer: acpmux answered and Claude Code is not installed, or its sign-in check says signed out or
    /// expired, or its login opened here waits to be confirmed. A read not made yet, a list acpmux did not answer
    /// (Claude Code not listed at all), an unknown sign-in (a Keychain login) and a configured Claude route never
    /// show it. Independent of the onboarding switch.
    public var needsChiefAgent: Bool {
        guard !chiefAgentHidden, let model = agentsModel, model.loaded, model.source?.chiefUsesRoute != true else { return false }
        if model.installable.contains(where: { $0.id == Self.chiefAgentID }) { return true }
        guard let agent = model.agents.first(where: { $0.id == Self.chiefAgentID }) else { return false }
        return agent.auth == .signedOut || agent.auth == .expired || model.awaitsConfirmation(agent)
    }

    /// Which Set Up card Chief's chat shows (``SetupCardHost``).
    public enum CardForm: Sendable, Equatable {
        /// The whole Set Up cmux card, while ``FirstRunSetup/shows``.
        case full
        /// Only the agent Chief answers through, while ``FirstRunSetup/needsChiefAgent``.
        case chief
    }

    /// The card Chief's chat shows now, or `nil` for none: the whole card while ``shows``, else its Chief form while
    /// ``needsChiefAgent``.
    public var cardForm: CardForm? { shows ? .full : needsChiefAgent ? .chief : nil }

    /// Reads the agents once (the shared model's first read), so ``needsChiefAgent`` can answer.
    public func checkChiefAgent(source: (any AgentSignInSource)?) {
        agents(source: source).start()
    }

    /// Hide on the Chief card: away for this launch; Chief's own reply still says what is missing.
    public func hideChiefAgent() {
        chiefAgentHidden = true
    }

    /// The card's agent installs and sign-ins, one for every card this launch: a card made again (another Home
    /// conversation, a new window) shows an install already running, starts no second one, and the install's
    /// sign-in still runs when it ends. `source` serves the first card's call.
    public func agents(source: (any AgentSignInSource)?) -> AgentsStepModel {
        if let agentsModel { return agentsModel }
        let model = AgentsStepModel(source: source)
        agentsModel = model
        return model
    }

    /// At launch, after the classic migration: a first run starts the card and marks the windows it replaces
    /// (`replacedKeys`: their once flags) shown. True when the card started now. Never twice, and never on an
    /// upgrade (`isFirstRun` false) or when the first-run Agents window already showed on this channel. With
    /// VoiceOver on (`screenReader`) the windows show as before: VoiceOver can press the Agents window's
    /// Chromium page, not the card's WebKit one (manaflow-ai/cmux#37809).
    @discardableResult
    public func begin(isFirstRun: Bool, replacedKeys: [String], screenReader: Bool = false) -> Bool {
        guard isFirstRun, !screenReader, !skipsOnboarding, defaults.string(forKey: Self.stateKey) == nil,
              !defaults.bool(forKey: OnboardingWindowPresenter.agentsShownKey) else { return false }
        for key in [OnboardingWindowPresenter.agentsShownKey] + replacedKeys { defaults.set(true, forKey: key) }
        defaults.set("pending", forKey: Self.stateKey)
        shows = true
        return true
    }

    /// What a launch's first-run steps do: start the card now, leave them to a card that started on an earlier
    /// launch (pending or ended: the old windows never run after it),
    /// or run the first-run windows (no card ever started).
    public enum Route: Equatable, Sendable { case startCard, cardOwns, windows }

    /// The launch's first-run route; starts the card when ``begin(isFirstRun:replacedKeys:screenReader:)`` does.
    public func route(isFirstRun: Bool, replacedKeys: [String], screenReader: Bool = false) -> Route {
        if begin(isFirstRun: isFirstRun, replacedKeys: replacedKeys, screenReader: screenReader) { return .startCard }
        return defaults.string(forKey: Self.stateKey) == nil ? .windows : .cardOwns
    }

    /// Hide, or first-run completion: the card leaves until explicitly reopened, and this Mac's first launch is finished.
    public func end() {
        guard defaults.string(forKey: Self.stateKey) != "ended" else { return }
        defaults.set(true, forKey: OnboardingWindowPresenter.historyShownKey)
        defaults.set("ended", forKey: Self.stateKey)
        shows = false
    }

    /// Shows the card again from a release action, preserving rows that were already answered.
    /// This explicit request works even when automatic onboarding is skipped. It never changes first-run
    /// markers or reopens the first-run windows, and refreshes the shared agent model without restarting installs.
    public func reopen() {
        defaults.set("reopened", forKey: Self.stateKey)
        agentsModel?.refresh(recheck: true)
        shows = true
    }

    /// Automatically dismisses first-run setup; a requested visit stays so completed rows can be reviewed.
    func complete() {
        guard defaults.string(forKey: Self.stateKey) != "reopened" else { return }
        end()
    }
}
