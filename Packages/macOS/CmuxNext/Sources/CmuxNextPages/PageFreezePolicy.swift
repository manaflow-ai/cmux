/// Decides when a cmux page in Chromium that nobody sees freezes: the app's hibernation
/// (``PageFreezing``), which freezes hidden browser tabs by the same rule (`browser.freezeHiddenTabs`),
/// so a Home, Settings, Diff, Files, Stats or chat page you switched away from, or whose window is
/// covered, minimized or ordered out, stops its timers, React effects and clocks after a grace
/// (perf-lead.md F3). Handed to each page by its ``PageChromiumHosting/freezePolicy``.
///
/// A page reports only changes of its own state, and the policy calls
/// ``PageWebView/freezeWhileHidden()`` when one is due. While frozen, the page's streams hold their
/// newest state for the thaw (``PageStreamFreezing``), so a push does not wake it; it thaws by
/// itself before it is seen and before a host call, a script or an event that cannot wait reaches
/// its document, and then reports ``hiddenPageWoke(_:)`` again.
///
/// ```swift
/// final class Freezing: PageFreezePolicy {
///     func hiddenPageWoke(_ page: PageWebView) { hiddenSince[ObjectIdentifier(page)] = .now }
///     func pageIsNoLongerHidden(_ page: PageWebView) { hiddenSince[ObjectIdentifier(page)] = nil }
/// }
/// ```
@MainActor
public protocol PageFreezePolicy: AnyObject {
    /// `page` is unseen and awake from now on: it hid, booted, finished a message to the host, or
    /// the host reached into it while unseen. Its grace starts again.
    ///
    /// - Parameter page: The unseen page; held weakly by the policy.
    func hiddenPageWoke(_ page: PageWebView)

    /// `page` is seen again, closed, or left Chromium: it is no longer a page to freeze.
    ///
    /// - Parameter page: The page.
    func pageIsNoLongerHidden(_ page: PageWebView)
}
