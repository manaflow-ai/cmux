/// How late a delayed wake of Home may fire, so the kernel can fold it into a wake that happens
/// anyway.
///
/// The same table as CmuxNextWakeups' `WakeLeeway` for a flexible delay (this Shared package can not
/// import the app's wakeup primitives; CmuxIrxTransport's `IrxWakeLeeway` is the same table):
/// Chromium's `kDefaultLeeway` of 8 ms below 1 s (`base/task/task_features.h`), and from 1 s on 10%
/// of the delay, at most 1 s (Apple's Energy Efficiency Guide for Mac Apps asks for at least 10%).
/// Every Home wait is a deadline, a backoff, a keepalive or a simulated latency, none a frame, so none
/// is precise. A leeway only makes a wake later, never earlier.
struct HomeWakeLeeway: Sendable, Equatable {
    /// The leeway of a delay below 1 s.
    static let subsecondLeeway: Duration = .milliseconds(8)
    /// The largest leeway any delay gets.
    static let maximumLeeway: Duration = .seconds(1)

    /// The delay the leeway is for.
    let delay: Duration

    init(delay: Duration) {
        self.delay = delay
    }

    /// How long after the deadline the wake may come: zero for no delay, 8 ms below 1 s, then
    /// min(10% of the delay, 1 s).
    var tolerance: Duration {
        guard delay > .zero else { return .zero }
        guard delay >= .seconds(1) else { return Self.subsecondLeeway }
        return min(delay / 10, Self.maximumLeeway)
    }
}
