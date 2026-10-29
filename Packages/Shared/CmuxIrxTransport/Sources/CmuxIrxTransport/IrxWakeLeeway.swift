/// How late a delayed wake of the transport may fire, so the kernel can fold it into a wake that
/// happens anyway.
///
/// The same table as CmuxNextWakeups' `WakeLeeway` for a flexible delay (this Shared package can not
/// import the app's wakeup primitives): Chromium's `kDefaultLeeway` of 8 ms below 1 s
/// (`base/task/task_features.h`), and from 1 s on 10% of the delay, at most 1 s (Apple's Energy
/// Efficiency Guide for Mac Apps asks for at least 10%; the cap keeps a 90 s receive deadline from
/// slipping by 9 s). Every transport wait is a timeout, a retry or a renewal, none a frame, so none is
/// precise.
struct IrxWakeLeeway: Sendable, Equatable {
    /// The leeway of a delay below 1 s.
    static let subsecondLeeway: Duration = .milliseconds(8)
    /// The largest leeway any delay gets.
    static let maximumLeeway: Duration = .seconds(1)

    /// The delay the leeway is for.
    let delay: Duration

    init(delay: Duration) {
        self.delay = delay
    }

    /// The leeway of a delay given in seconds (the V2 control service's clock seam). NaN and a
    /// negative delay are no delay; `Duration.seconds` traps past Int64 seconds, so a delay past
    /// 2^31 s (68 years) is clamped there.
    init(seconds: Double) {
        delay = seconds.isNaN || seconds <= 0 ? .zero : .seconds(min(seconds, 2_147_483_648))
    }

    /// How long after the deadline the wake may come: zero for no delay, 8 ms below 1 s, then
    /// min(10% of the delay, 1 s).
    var tolerance: Duration {
        guard delay > .zero else { return .zero }
        guard delay >= .seconds(1) else { return Self.subsecondLeeway }
        return min(delay / 10, Self.maximumLeeway)
    }
}
