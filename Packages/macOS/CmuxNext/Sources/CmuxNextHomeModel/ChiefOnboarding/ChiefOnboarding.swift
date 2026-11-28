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
/// Chief first and one thing at a time.
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
    public private(set) var shows: Bool
    /// Whether this launch decided if Meet Chief shows (``begin(freshInstall:)`` ran, or an earlier launch started it).
    public private(set) var decided: Bool
    /// The step on screen.
    public private(set) var step: ChiefOnboardingStep = .meet
    /// Shown again by ``reopen()``: on any Chief chat, until a next message there or its end.
    public private(set) var reopened = false
    /// The last settings write failed: the step says so, and shows the setting's value again.
    public private(set) var writeFailed = false
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
        let state = defaults.string(forKey: Self.stateKey)
        shows = !skipsOnboarding && state == "pending"
        decided = skipsOnboarding || state != nil
    }

    /// Decides this launch: a fresh install (Chief's welcome has not shown yet) starts Meet Chief, once; never an
    /// upgrade, never after it ended, never while onboarding is skipped.
    /// - Parameter freshInstall: This install's first run, before it met Chief (``ChiefIntroStore/welcomePending``).
    /// - Returns: True when it started now.
    @discardableResult
    public func begin(freshInstall: Bool) -> Bool {
        decided = true
        guard freshInstall, !skipsOnboarding, defaults.string(forKey: Self.stateKey) == nil else { return false }
        defaults.set("pending", forKey: Self.stateKey)
        step = .meet
        shows = true
        return true
    }

    /// Whether Chief's welcome and the Set Up cmux card wait: Meet Chief shows, or the launch has not decided yet.
    public var holdsWelcome: Bool { shows || !decided }

    /// Returns once Meet Chief is not on screen: at once when it is not. The first run's own chat workspace waits on this, so Home
    /// and Meet Chief stay in front until it ended (Continue, Skip, Start chatting): onboarding-golden-path-production red 2.
    public func untilEnded() async {
        for await shows in ObservationStream({ self.shows }) where !shows { return }
    }

    /// The steps, in order.
    public var steps: [ChiefOnboardingStep] { ChiefOnboardingStep.allCases }
    /// The step's place, from 0.
    public var index: Int { steps.firstIndex(of: step) ?? 0 }
    /// Whether Back has a step to go to.
    public var canGoBack: Bool { index > 0 }
    /// Whether the step is the last one (its primary button starts the chat).
    public var isLast: Bool { index == steps.count - 1 }

    /// The primary button: the next step, or on the last one, the end.
    public func next() {
        guard shows else { return }
        if isLast { return finish() }
        step = steps[index + 1]
        writeFailed = false
    }

    /// Back: the step before; nothing on the first.
    public func back() {
        guard shows, canGoBack else { return }
        step = steps[index - 1]
        writeFailed = false
    }

    /// Skip, the last step's Start chatting, or the person started chatting: it ends for good, at any step.
    public func finish() {
        guard shows else { return }
        defaults.set("done", forKey: Self.stateKey)
        shows = false
        reopened = false
        step = .meet
    }

    /// What a Chief chat shows: the first run only on the person's only Chief chat while it is empty, ended by its
    /// first message; Meet Chief from the palette (``reopen()``) on any Chief chat, ended by the next message there.
    /// - Parameters:
    ///   - lastSeq: The chat's newest message (0: none).
    ///   - shownAt: The chat's newest message when the card first showed there, nil before.
    ///   - otherChiefs: How many other Chief chats the person has (``HomeArchivedChiefs``).
    public func place(chatAt lastSeq: UInt64, shownAt: UInt64?, otherChiefs: Int) -> ChiefOnboardingPlace {
        guard shows else { return .hidden }
        if reopened { return shownAt.map { lastSeq > $0 } == true ? .ends : .shows }
        guard otherChiefs == 0 else { return .hidden }
        return lastSeq == 0 ? .shows : .ends
    }

    /// Shows it again from the first step on the Chief chat (Meet Chief in the palette, Debug, captures), also in a
    /// chat with messages (``place(chatAt:shownAt:otherChiefs:)``); it stays ended for the next launch.
    public func reopen() {
        decided = true
        step = .meet
        writeFailed = false
        reopened = true
        shows = true
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
    public var canShrinkText: Bool { settings.map { $0.textSize > $0.textSizeRange.lowerBound } ?? false }
    /// Whether the text can get one point larger.
    public var canGrowText: Bool { settings.map { $0.textSize < $0.textSizeRange.upperBound } ?? false }

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
        guard let settings else { return nil }
        let size = min(max((settings.textSize + points).rounded(), settings.textSizeRange.lowerBound), settings.textSizeRange.upperBound)
        guard size != settings.textSize else { return nil }
        return write { try await settings.setTextSize(size) }
    }

    /// Runs one settings write; its failure sets ``writeFailed`` and drops a pending pick, unless a newer write
    /// came since.
    private func write(_ body: @escaping @MainActor () async throws -> Void) -> Task<Void, Never> {
        let id = UUID()
        newestWrite = id
        writeFailed = false
        // task-owner: one settings write; it ends with the write, and a newer write supersedes its answer.
        return Task { [weak self] in
            var failed = false
            do { try await body() } catch { failed = true }
            guard let self, self.newestWrite == id else { return }
            self.newestWrite = nil
            self.pendingMode = nil
            self.writeFailed = failed
        }
    }
}
