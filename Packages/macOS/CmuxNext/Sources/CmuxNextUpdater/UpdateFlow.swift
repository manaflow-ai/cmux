import Foundation

/// The install gate over Sparkle's flow (R114): downloads stay invisible,
/// a ready update is one quiet card, one click installs unless agents are
/// in a turn (then the click waits for them), and a quit installs a staged
/// update unless `updates.installOnQuit` is off. A pure value: the App
/// feeds events and performs the effects.
nonisolated public struct UpdateFlow: Equatable, Sendable {
    public private(set) var phase: UpdateIndicatorPhase = .hidden
    public private(set) var blockers: UpdateBlockers = .none
    /// The user asked to install; held until the update is staged and no
    /// agent is busy.
    public private(set) var installRequested = false
    /// The user asked to check: checking, downloading and the result show.
    public private(set) var userAsked = false
    /// The "install although work runs" dialog is open.
    public private(set) var confirmationOpen = false

    public init() {}

    public mutating func handle(_ event: UpdateFlowEvent, preferences: UpdatePreferences) -> [UpdateFlowEffect] {
        []
    }

    public func card(preferences: UpdatePreferences, minuteOfDay: Int) -> UpdateCard? {
        nil
    }

    public func showsSettingsBadge(preferences: UpdatePreferences) -> Bool {
        false
    }
}
