import Foundation

/// How strictly a delayed wake honors its deadline. The cases and their meaning are Chromium's
/// `base/task/delay_policy.h` (`subtle::DelayPolicy`); ``WakeLeeway`` turns a policy and a delay into
/// the window the wake may fire in.
public enum DelayPolicy: Sendable, Hashable, CaseIterable {
    /// Never before the deadline, at most the leeway after it (`kFlexibleNoSooner`, the default of
    /// Chromium's `PostDelayedTask`). Debounces, timeouts and delayed show/hide use this.
    case flexibleNoSooner
    /// At most the leeway before the deadline, never after it (`kFlexiblePreferEarly`). For a
    /// deadline that must not be late but may run a little early, such as a lease renewal.
    case flexiblePreferEarly
    /// Exactly at the deadline, no leeway, no alignment (`kPrecise`). Only below
    /// ``maxPreciseDelay``; a longer precise delay becomes ``flexibleNoSooner``.
    case precise

    /// The longest delay that can stay precise: 36 ms, "slightly above 30Hz timer"
    /// (`kDefaultMaxPreciseDelay`, `base/task/task_features.cc`).
    public static let maxPreciseDelay: Duration = .milliseconds(36)

    /// The policy that applies to `delay`, as Chromium's `MaybeOverrideDelayPolicy`
    /// (`base/task/delay_policy.h`): a delay of zero or less is due now and runs as `.precise`;
    /// `.precise` at or above ``maxPreciseDelay`` becomes `.flexibleNoSooner`. A precise wake is a
    /// wake no other deadline can share, so only a delay too short to coalesce keeps it.
    public func effective(for delay: Duration) -> DelayPolicy {
        if delay <= .zero { return .precise }
        return self == .precise && delay >= Self.maxPreciseDelay ? .flexibleNoSooner : self
    }
}
