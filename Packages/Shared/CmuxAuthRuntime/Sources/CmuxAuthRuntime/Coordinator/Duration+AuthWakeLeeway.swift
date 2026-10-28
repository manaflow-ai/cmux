import Foundation

extension Duration {
    /// How late a sleep of this length may end, so the kernel can fold its wake into one it already has.
    ///
    /// Chromium gives every delayed task 8 ms of leeway (`kDefaultLeeway`, `base/task/task_features.h`)
    /// and keeps delays below 36 ms precise (`kMaxPreciseDelay`, `base/task/delay_policy.h`); Apple's
    /// Energy Efficiency Guide for Mac Apps asks for at least 10% of the interval. This is the larger of
    /// the two, capped at 1 s so a 60 s timeout slips by at most a second: the window CmuxNextWakeups'
    /// `Backoff` sleeps with, and its `WakeLeeway` from 1 s on. `@usableFromInline` because the
    /// public default `retrySleep` of `PushRegistrationService.init` reads it.
    @usableFromInline var authWakeLeeway: Duration {
        guard self >= .milliseconds(36) else { return .zero }
        return max(.milliseconds(8), min(self / 10, .seconds(1)))
    }
}
