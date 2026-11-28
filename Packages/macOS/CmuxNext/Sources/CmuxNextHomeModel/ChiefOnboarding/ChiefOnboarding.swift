public import Foundation
public import Observation
import CmuxNextCompat

/// Meet Chief: the short first-run introduction on the person's empty Chief chat, so they know who Chief is, what
/// it does for them and what it may do on this Mac before they start (David Beyer's first run, 2026-11-20: "who is
/// Chief, what permissions does it have, what does it do for me" was the moment he would have left).
///
/// Three steps, simplest first (``ChiefOnboardingStep``): who Chief is with what it does (agents, memory,
/// follow-ups); what it may do on this Mac, with the choice of ``ChiefPermissionMode`` and where to change it later;
/// then how cmux looks (density and text size, live). Cloud and the app store are not on a first run. Skip ends it
/// at any step.
///
/// It starts once per install, on a fresh one only (``begin(freshInstall:)``), and ends for good when the person
/// finishes or skips it; a relaunch while it is pending shows it again from the first step. Until the launch decided
/// (``holdsWelcome``) and while it shows, Home holds Chief's welcome and the Set Up cmux card, so the person meets
/// Chief first and one thing at a time. The rules are `welcome.onboarding*` (cmux-home-rules `welcome/onboarding.rs`);
/// this model keeps the default they name and runs the settings writes.
///
/// ```swift
/// let onboarding = ChiefOnboarding(defaults: .standard, settings: appSettings)
/// onboarding.begin(freshInstall: isFirstRun && intro.welcomePending)
/// ```
@MainActor
@Observable
public final class ChiefOnboarding {
    /// UserDefaults: absent before a first run started it, "pending" while it waits to be finished, "done" after.
    public static let stateKey = "home.firstRun.chiefOnboarding"

    /// Whether Home shows Meet Chief now.
    public var shows: Bool { now.shows }
    /// Whether this launch decided if Meet Chief shows (``begin(freshInstall:)`` ran, or an earlier launch started it).
    public var decided: Bool { now.decided }
    /// The step on screen.
    public var step: ChiefOnboardingStep { now.step }
    /// Shown again by ``reopen(step:)``: on any Chief chat, until a next message there or its end.
    public var reopened: Bool { now.reopened }
    /// The last settings write failed: the step says so, and shows the setting's value again.
    public var writeFailed: Bool { now.writeFailed }
    /// The step's place, from 0.
    public var index: Int { now.index }
    /// Whether Back has a step to go to.
    public var canGoBack: Bool { now.canGoBack }
    /// Whether the step is the last one (its primary button starts the chat).
    public var isLast: Bool { now.isLast }
    /// Whether Chief's welcome and the Set Up cmux card wait: Meet Chief shows, or the launch has not decided yet.
    public var holdsWelcome: Bool { now.holdsWelcome }
    /// The state the properties above read: the rules' last answer (`welcome.onboarding`).
    private var now = View()
    /// The person's permission pick while its write runs (optimistic), else nil.
    private var pendingMode: ChiefPermissionMode?
    /// The newest write: an older write's answer never undoes a newer pick.
    @ObservationIgnored private var newestWrite: UUID?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let skipsOnboarding: Bool
    /// The settings the steps read and write; nil (no settings yet) shows the defaults, read-only.
    @ObservationIgnored public let settings: (any ChiefOnboardingSettings)?

    /// - Parameters:
    ///   - defaults: Where the once-per-install state lives (the app passes `.standard`; tests a suite).
    ///   - settings: What the steps change (the app's settings).
    ///   - skipsOnboarding: `--skip-onboarding` / `CMUX_NEXT_SKIP_ONBOARDING=1`: it stays away this launch, and a
    ///     pending one returns on the next launch that does not skip.
    public init(defaults: UserDefaults, settings: (any ChiefOnboardingSettings)?, skipsOnboarding: Bool = false) {
        self.defaults = defaults
        self.settings = settings
        self.skipsOnboarding = skipsOnboarding
        apply("launch")
    }

    /// Decides this launch: a fresh install (Chief's welcome has not shown yet) starts Meet Chief, once; never an
    /// upgrade, never after it ended, never while onboarding is skipped.
    /// - Parameter freshInstall: This install's first run, before it met Chief (``ChiefIntroStore/welcomePending``).
    /// - Returns: True when it started now.
    @discardableResult
    public func begin(freshInstall: Bool) -> Bool { apply("begin", freshInstall: freshInstall) }

    /// Returns once Meet Chief is not on screen: at once when it is not. The first run's own chat workspace waits on this, so Home
    /// and Meet Chief stay in front until it ended (Continue, Skip, Start chatting): onboarding-golden-path-production red 2.
    public func untilEnded() async {
        for await shows in ObservationStream({ self.shows }) where !shows { return }
    }

    /// The steps, in order.
    public var steps: [ChiefOnboardingStep] { ChiefOnboardingStep.allCases }

    /// The primary button: the next step, or on the last one, the end.
    public func next() { apply("next") }

    /// Back: the step before; nothing on the first.
    public func back() { apply("back") }

    /// Skip, the last step's Start chatting, or the person started chatting: it ends for good, at any step.
    public func finish() { apply("finish") }

    /// What a Chief chat shows: the first run only on the person's only Chief chat while it is empty, ended by its
    /// first message; Meet Chief from the palette (``reopen(step:)``) on any Chief chat, ended by the next message there.
    /// - Parameters:
    ///   - lastSeq: The chat's newest message (0: none).
    ///   - shownAt: The chat's newest message when the card first showed there, nil before.
    ///   - otherChiefs: How many other Chief chats the person has (``HomeArchivedChiefs``).
    public func place(chatAt lastSeq: UInt64, shownAt: UInt64?, otherChiefs: Int) -> ChiefOnboardingPlace {
        let input = PlaceInput(state: now, lastSeq: lastSeq, shownAt: shownAt, otherChiefs: otherChiefs)
        return welcomeRule("welcome.onboardingPlace", input, fallback: PlaceReply(place: .hidden)).place
    }

    /// Shows it again on the Chief chat (Meet Chief in the palette, Debug, captures), also in a chat with messages
    /// (``place(chatAt:shownAt:otherChiefs:)``); it stays ended for the next launch.
    /// - Parameter step: The step it shows (a ``ChiefOnboardingStep`` name; nil or unknown: the first).
    public func reopen(step: String? = nil) { apply("reopen", step: step) }

    /// Runs `event` through `welcome.onboarding`: stores what it says under ``stateKey`` and takes its state.
    /// - Returns: Whether `begin` started it now.
    @discardableResult
    private func apply(_ event: String, freshInstall: Bool = false, step target: String? = nil) -> Bool {
        let input = Input(state: now, event: event, stored: defaults.string(forKey: Self.stateKey), skips: skipsOnboarding,
                          freshInstall: freshInstall, step: target)
        guard let reply: Reply = welcomeRule("welcome.onboarding", input, fallback: nil) else { return false }
        if let store = reply.store { defaults.set(store, forKey: Self.stateKey) }
        if reply.view != now { now = reply.view }
        return reply.started
    }

    // MARK: What Chief may do

    /// The mode the access step shows: the person's pick while it saves, else the setting's.
    public var mode: ChiefPermissionMode { pendingMode ?? settings?.mode ?? .default }
    /// Whether an administrator sets the mode.
    public var modeManaged: Bool { settings?.modeManaged ?? false }
    /// Whether the person can change the mode here: there are settings, and no administrator sets it.
    public var canChooseMode: Bool { settings != nil && !modeManaged }

    /// The person picks `mode`: it shows at once and is written as their own setting; a failed write puts the
    /// setting's mode back and sets ``writeFailed``.
    /// - Parameter mode: The mode the person picked.
    /// - Returns: The write, for a caller that waits on it (tests); nil when nothing is written.
    @discardableResult
    public func choose(_ mode: ChiefPermissionMode) -> Task<Void, Never>? {
        guard let settings, canChooseMode, mode != self.mode else { return nil }
        pendingMode = mode
        return write { try await settings.setMode(mode) }
    }

    // MARK: How cmux looks

    /// The density in effect (nil: one Meet Chief does not offer); the default with no settings.
    public var density: ChiefOnboardingDensity? { settings.map(\.density) ?? .cozy }
    /// The interface text size in effect, in points.
    public var textSize: Double { settings?.textSize ?? 12 }
    /// Whether the text can get one point smaller.
    public var canShrinkText: Bool { settings.map { look($0).canShrink } ?? false }
    /// Whether the text can get one point larger.
    public var canGrowText: Bool { settings.map { look($0).canGrow } ?? false }

    /// The person picks `density`; it applies live.
    /// - Returns: The write (tests wait on it); nil when nothing is written.
    @discardableResult
    public func chooseDensity(_ density: ChiefOnboardingDensity) -> Task<Void, Never>? {
        guard let settings, density != self.density else { return nil }
        return write { try await settings.setDensity(density) }
    }

    /// The text gets one point smaller (`by: -1`) or larger (`by: 1`), within the setting's range; it applies live.
    /// - Returns: The write (tests wait on it); nil at the end of the range.
    @discardableResult
    public func changeTextSize(by points: Double) -> Task<Void, Never>? {
        guard let settings, let size = look(settings, by: points).size else { return nil }
        return write { try await settings.setTextSize(size) }
    }

    /// The look step's text size rules (`welcome.onboardingLook`) over the setting's size and range.
    private func look(_ settings: any ChiefOnboardingSettings, by points: Double = 0) -> LookReply {
        let input = LookInput(size: settings.textSize, min: settings.textSizeRange.lowerBound, max: settings.textSizeRange.upperBound, points: points)
        return welcomeRule("welcome.onboardingLook", input, fallback: LookReply(canShrink: false, canGrow: false, size: nil))
    }

    /// Runs one settings write; its failure sets ``writeFailed`` and drops a pending pick, unless a newer write
    /// came since.
    private func write(_ body: @escaping @MainActor () async throws -> Void) -> Task<Void, Never> {
        let id = UUID()
        newestWrite = id
        now.writeFailed = false
        // task-owner: one settings write; it ends with the write, and a newer write supersedes its answer.
        return Task { [weak self] in
            var failed = false
            do { try await body() } catch { failed = true }
            guard let self, self.newestWrite == id else { return }
            self.newestWrite = nil
            self.pendingMode = nil
            self.now.writeFailed = failed
        }
    }

    // The onboarding ops' wire shapes (cmux-home-rules `welcome/onboarding.rs`).
    private nonisolated struct View: Codable, Equatable {
        var shows = false, decided = false, step = ChiefOnboardingStep.meet, reopened = false, writeFailed = false
        var index = 0, canGoBack = false, isLast = false, holdsWelcome = true
    }
    private nonisolated struct Input: Encodable { var state: View, event: String, stored: String?, skips, freshInstall: Bool, step: String? }
    private nonisolated struct Reply: Decodable { var view: View, store: String?, started: Bool }
    private nonisolated struct PlaceInput: Encodable { var state: View, lastSeq: UInt64, shownAt: UInt64?, otherChiefs: Int }
    private nonisolated struct PlaceReply: Decodable { var place: ChiefOnboardingPlace }
    private nonisolated struct LookInput: Encodable { var size, min, max, points: Double }
    private nonisolated struct LookReply: Decodable { var canShrink, canGrow: Bool, size: Double? }
}
