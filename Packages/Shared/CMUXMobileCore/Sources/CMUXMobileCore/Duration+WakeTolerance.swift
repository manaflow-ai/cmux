import Foundation

extension Duration {
    /// The tolerance a one-shot wait of this length passes to `sleep(for:tolerance:)`, so the kernel
    /// may fire it together with other wakes instead of on its own.
    ///
    /// The same rule as CmuxNextWakeups' `WakeLeeway` for a flexible deadline, which CMUXMobileCore
    /// cannot link (it also builds for iOS): from 1 s on, min(10%, 1 s), as Apple's Energy
    /// Efficiency Guide ("Minimize Timer Usage") asks; below 1 s, 8 ms, Chromium's `kDefaultLeeway`
    /// (`base/task/task_features.h`); zero for a wait that is not positive. A sleep only fires late,
    /// so the tolerance never shortens the wait.
    var flexibleWakeTolerance: Duration {
        guard self > .zero else { return .zero }
        guard self >= .seconds(1) else { return .milliseconds(8) }
        return Swift.min(self / 10, .seconds(1))
    }
}
