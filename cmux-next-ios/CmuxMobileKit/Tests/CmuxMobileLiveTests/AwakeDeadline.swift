import Foundation

/// A test wait's bound in time the test process was awake, not wall-clock time.
///
/// The kit's macOS `swift test` starts about 2,400 tests at once, and on a CI runner the whole
/// process then stalls for 30 to 50 s with no test making progress (kit jobs 134162060756,
/// 134382697039, 134052809767, 133945479529 on 2026-11-17: no output for that long, then every
/// test in flight reported at once). A poll bounded by `ContinuousClock.now + 20 s` spent its
/// whole budget inside that stall and failed on its first look after it, although the condition
/// came true a moment later. Each poll here charges the time since the previous one, but never
/// more than `maxCharge`: a stall costs one charge, and a condition that never comes true still
/// ends the wait after about `budget` of polling.
struct AwakeDeadline {
    private var left: Duration
    private var last = ContinuousClock.now
    private static let maxCharge: Duration = .milliseconds(100)

    init(_ budget: Duration) { left = budget }

    /// Charges the time since the last call (at most `maxCharge`); false once the budget is spent.
    mutating func hasTimeLeft() -> Bool {
        let now = ContinuousClock.now
        left -= min(now - last, Self.maxCharge)
        last = now
        return left > .zero
    }
}
