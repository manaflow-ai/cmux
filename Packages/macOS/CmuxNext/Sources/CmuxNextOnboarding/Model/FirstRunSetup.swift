public import Foundation
public import Observation

/// Whether Home shows the Set Up cmux card (goal next-first-run-setup; Lawrence 2026-10-09: "i do not want new
/// window ... just drop user into main screen asap"). A first run starts it in place of the first-run windows:
/// the Agents window, Bring your history over Home and the CLI toast at launch each mark themselves shown, so
/// their rows on the card are the one place they are offered. Hide or every row done ends it for good, per
/// channel (`defaults`). Settings keeps every row.
@MainActor
@Observable
public final class FirstRunSetup {
    /// UserDefaults: "pending" while the card shows, "ended" once hidden or done.
    public static let stateKey = "home.firstRun.setupCard"
    /// Whether Home shows the card now.
    public private(set) var shows: Bool
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        shows = defaults.string(forKey: Self.stateKey) == "pending"
    }

    /// At launch, after the classic migration: a first run starts the card and marks the windows it replaces
    /// (`replacedKeys`: their once flags) shown. True when the card started now. Never twice, and never on an
    /// upgrade (`isFirstRun` false) or when the first-run Agents window already showed on this channel.
    @discardableResult
    public func begin(isFirstRun: Bool, replacedKeys: [String]) -> Bool {
        guard isFirstRun, defaults.string(forKey: Self.stateKey) == nil,
              !defaults.bool(forKey: OnboardingWindowPresenter.agentsShownKey) else { return false }
        for key in [OnboardingWindowPresenter.agentsShownKey] + replacedKeys { defaults.set(true, forKey: key) }
        defaults.set("pending", forKey: Self.stateKey)
        shows = true
        return true
    }

    /// Hide, or every row done: the card leaves for good.
    public func end() {
        guard defaults.string(forKey: Self.stateKey) != "ended" else { return }
        defaults.set("ended", forKey: Self.stateKey)
        shows = false
    }
}
