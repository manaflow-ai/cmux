import CmuxNextWakeups

extension LifecycleDeadlineRig {
    /// A deadline scheduler whose wakes nothing fires: a page's Chromium or claim fallback on it never runs out (the
    /// suites that are not about the fallback). It holds its queue and its main-thread scheduler itself.
    static var never: MainDeadlineScheduler { LifecycleDeadlineRig().scheduler }
}
