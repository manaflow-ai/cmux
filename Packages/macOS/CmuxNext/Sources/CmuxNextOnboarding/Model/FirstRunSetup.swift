public import Foundation
public import Observation

/// Whether Home shows the Set Up cmux card (goal next-first-run-setup; Lawrence 2026-10-09: "i do not want new
/// window ... just drop user into main screen asap"). A first run starts it in place of the first-run windows:
/// the Agents window and the CLI toast at launch mark themselves shown, so their rows on the card are the one
/// place they are offered. Bring your history keeps its own once flag: the card's chat history row sets it
/// only once that page showed or the row (or the card) was dismissed. The launch's classic import asks on its cmux
/// Classic row (``askClassic(_:)``) instead of a dialog beside it. Hide or every row done ends it for good, per
/// channel (`defaults`). Settings keeps every row.
@MainActor
@Observable
public final class FirstRunSetup {
    /// UserDefaults: "pending" while the card shows, "ended" once hidden or done.
    public static let stateKey = "home.firstRun.setupCard"
    /// Whether Home shows the card now.
    public private(set) var shows: Bool
    /// Bring your history showed, or its row was dismissed (``OnboardingWindowPresenter/historyShownKey``).
    public private(set) var historyDone: Bool
    @ObservationIgnored private let defaults: UserDefaults

    /// `skipsOnboarding` (`--skip-onboarding`, `CMUX_NEXT_SKIP_ONBOARDING=1`): the card stays away for this launch
    /// and starts on none, and a card still pending returns on the next launch that does not skip.
    public init(defaults: UserDefaults = .standard, skipsOnboarding: Bool = false) {
        self.defaults = defaults
        self.skipsOnboarding = skipsOnboarding
        shows = !skipsOnboarding && defaults.string(forKey: Self.stateKey) == "pending"
        historyDone = defaults.bool(forKey: OnboardingWindowPresenter.historyShownKey)
    }

    @ObservationIgnored private let skipsOnboarding: Bool
    @ObservationIgnored private var agentsModel: AgentsStepModel?

    /// The card's agent installs and sign-ins, one for every card this launch: a card made again (another Home
    /// conversation, a new window) shows an install already running, starts no second one, and the install's
    /// sign-in still runs when it ends. `source` serves the first card's call.
    public func agents(source: (any AgentSignInSource)?) -> AgentsStepModel {
        if let agentsModel { return agentsModel }
        let model = AgentsStepModel(source: source)
        agentsModel = model
        return model
    }

    /// The chat history row is answered: its page showed, or the person dismissed it.
    public func historyAnswered() {
        defaults.set(true, forKey: OnboardingWindowPresenter.historyShownKey)
        historyDone = true
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
    /// launch (pending or ended: the old windows never run after it, so Bring your history's flag stays the row's),
    /// or run the first-run windows (no card ever started).
    public enum Route: Equatable, Sendable { case startCard, cardOwns, windows }

    /// The launch's first-run route; starts the card when ``begin(isFirstRun:replacedKeys:screenReader:)`` does.
    public func route(isFirstRun: Bool, replacedKeys: [String], screenReader: Bool = false) -> Route {
        if begin(isFirstRun: isFirstRun, replacedKeys: replacedKeys, screenReader: screenReader) { return .startCard }
        return defaults.string(forKey: Self.stateKey) == nil ? .windows : .cardOwns
    }

    /// What the launch's classic import would bring, shown on the card's cmux Classic row until answered.
    public struct ClassicOffer: Equatable, Sendable {
        public var workspaces: Int
        /// The classic app that saved it, as its Dock names it (``ClassicImportPlan/Source/appName``).
        public var app: String
        /// When it saved (seconds since 1970), and whether that app is still open (its autosave, not its quit save).
        public var savedAt: Double
        public var running: Bool
        /// Import reconnects these and resumes these, so the row says so.
        public var sshWorkspaces: Int
        public var agentChats: Int

        public init(workspaces: Int, app: String, savedAt: Double, running: Bool, sshWorkspaces: Int = 0, agentChats: Int = 0) {
            (self.workspaces, self.app, self.savedAt, self.running) = (workspaces, app, savedAt, running)
            (self.sshWorkspaces, self.agentChats) = (sshWorkspaces, agentChats)
        }

        public init(_ plan: ClassicImportPlan) {
            self.init(workspaces: plan.workspaces.count, app: plan.source.appName, savedAt: plan.savedAt, running: plan.classicRunning,
                      sshWorkspaces: plan.sshWorkspaces, agentChats: plan.agentChats)
        }
    }

    /// The cmux Classic row's offer while the launch's import asks, and after it was answered.
    public private(set) var classic: ClassicOffer?
    /// The row's answer: accepted or declined, nil while it asks (or before any ask).
    public private(set) var classicAnswer: ClassicImportAnswer?
    /// The launch's classic migration has not decided yet whether it asks: the card does not end before it has,
    /// so a migration that reads slowly cannot lose its row (as the chat history row waits for its read).
    public private(set) var awaitsClassic = false
    @ObservationIgnored private var classicReply: CheckedContinuation<ClassicImportAnswer, Never>?

    /// The launch's classic migration starts while the card shows; ``classicSettled()`` ends the wait. Returns self.
    @discardableResult
    public func expectingClassic() -> FirstRunSetup {
        if shows { awaitsClassic = true }
        return self
    }

    /// The launch's classic migration has finished asking (or found nothing to ask).
    public func classicSettled() {
        awaitsClassic = false
    }

    /// The launch's classic import asks on the cmux Classic row: the answer is the person's own click there (Import,
    /// or Skip, a No the migration keeps), or unanswered when the card leaves first (Hide: the next launch asks
    /// again). Nil when the card does not show: the caller asks with its dialog, as before.
    public func askClassic(_ offer: ClassicOffer) async -> ClassicImportAnswer? {
        guard shows, classicReply == nil else { return nil }
        classic = offer
        classicAnswer = nil
        return await withCheckedContinuation { classicReply = $0 }
    }

    /// The cmux Classic row's button (Import or Skip), on the person's click; nothing when no import asks.
    public func answerClassic(_ answer: ClassicImportAnswer) {
        guard let reply = classicReply, answer != .unanswered else { return }
        classicReply = nil
        classicAnswer = answer
        reply.resume(returning: answer)
    }

    /// Hide, or every row done: the card leaves for good, and its chat history row with it. An import still asking
    /// on the cmux Classic row is left unanswered, so the next launch asks again with its dialog.
    public func end() {
        guard defaults.string(forKey: Self.stateKey) != "ended" else { return }
        if let reply = classicReply {
            classicReply = nil
            reply.resume(returning: .unanswered)
        }
        historyAnswered()
        defaults.set("ended", forKey: Self.stateKey)
        shows = false
    }
}
