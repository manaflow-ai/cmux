public import Foundation
public import Observation

/// Whether Home shows the Set Up cmux card (goal next-first-run-setup; Lawrence 2026-10-09: "i do not want new
/// window ... just drop user into main screen asap"). A first run starts it in place of the first-run windows:
/// the Agents window and the CLI toast at launch mark themselves shown, so their rows on the card are the one
/// place they are offered. Bring your history keeps its own once flag: the card's chat history row sets it
/// only once that page showed or the row (or the card) was dismissed. Hide or every row done ends it for good, per
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

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        shows = defaults.string(forKey: Self.stateKey) == "pending"
        historyDone = defaults.bool(forKey: OnboardingWindowPresenter.historyShownKey)
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
        guard isFirstRun, !screenReader, defaults.string(forKey: Self.stateKey) == nil,
              !defaults.bool(forKey: OnboardingWindowPresenter.agentsShownKey) else { return false }
        for key in [OnboardingWindowPresenter.agentsShownKey] + replacedKeys { defaults.set(true, forKey: key) }
        defaults.set("pending", forKey: Self.stateKey)
        shows = true
        return true
    }

    /// What a launch's first-run steps do: start the card now, leave them to a card that started on an earlier
    /// launch (pending or ended: the old windows never run after it, so Bring your history's flag stays the row's),
    /// or run the first-run windows (no card ever started).
    public enum Route: Sendable { case startCard, cardOwns, windows }

    /// The launch's first-run route; starts the card when ``begin(isFirstRun:replacedKeys:screenReader:)`` does.
    public func route(isFirstRun: Bool, replacedKeys: [String], screenReader: Bool = false) -> Route {
        if begin(isFirstRun: isFirstRun, replacedKeys: replacedKeys, screenReader: screenReader) { return .startCard }
        return defaults.string(forKey: Self.stateKey) == nil ? .windows : .cardOwns
    }

    /// Hide, or every row done: the card leaves for good, and its chat history row with it.
    public func end() {
        guard defaults.string(forKey: Self.stateKey) != "ended" else { return }
        historyAnswered()
        defaults.set("ended", forKey: Self.stateKey)
        shows = false
    }
}
