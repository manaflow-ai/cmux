extension Duration {
    /// How late an updater sleep of this length may end, so the kernel can fold its wake into one it
    /// already has.
    ///
    /// Chromium gives every delayed task 8 ms of leeway (`kDefaultLeeway`, `base/task/task_features.h`)
    /// and keeps delays below 36 ms precise (`kMaxPreciseDelay`, `base/task/delay_policy.h`); Apple's
    /// Energy Efficiency Guide for Mac Apps asks for at least 10% of the interval. This is the larger of
    /// the two, capped at 1 s: the window CmuxNextWakeups' `Backoff` and `WakeLeeway` use.
    var updateWakeLeeway: Duration {
        guard self >= .milliseconds(36) else { return .zero }
        return Swift.max(.milliseconds(8), Swift.min(self / 10, .seconds(1)))
    }
}
