import CmuxNextPages
import CmuxNextSettings

/// Red-commit stub (the next commit implements it) with the base behavior: no hidden cmux page
/// freezes. Only the tests make it; the app does not use it yet.
@MainActor
final class CmuxPageFreezing: PageFreezePolicy {
    /// The clock (tests set it).
    var now: () -> ContinuousClock.Instant = { .now }
    /// Pages frozen so far.
    private(set) var frozenCount = 0

    init(clock: any Clock<Duration> = ContinuousClock()) {}

    /// Hidden pages the policy waits on.
    var waitingCount: Int { 0 }
    /// A page is due later and the timer for it runs.
    var hasDeadline: Bool { false }

    func update(setting: BrowserHibernationSetting) {}
    func hiddenPageWoke(_ page: PageWebView) {}
    func pageIsNoLongerHidden(_ page: PageWebView) {}
    func replan() {}
}
