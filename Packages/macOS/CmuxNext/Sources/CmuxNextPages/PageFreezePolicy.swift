/// Decides when a hidden cmux page in Chromium freezes: the app's hibernation, which freezes hidden
/// browser tabs by the same rule (`browser.freezeHiddenTabs`), so a Settings, Diff, Files, Stats or
/// chat page you switched away from stops its timers, React effects and clocks after a grace
/// (perf-lead.md F3). Handed to each page by its ``PageChromiumHosting/freezePolicy``.
///
/// A page reports only changes of its own state, and the policy calls
/// ``PageWebView/freezeWhileHidden()`` when one is due. The page thaws by itself before it shows
/// and before any call or push from the host reaches its document (a frozen page runs no script),
/// and then reports ``hiddenPageWoke(_:)`` again, so a page the host keeps feeding never freezes.
///
/// ```swift
/// final class Freezing: PageFreezePolicy {
///     func hiddenPageWoke(_ page: PageWebView) { hiddenSince[ObjectIdentifier(page)] = .now }
///     func pageIsNoLongerHidden(_ page: PageWebView) { hiddenSince[ObjectIdentifier(page)] = nil }
/// }
/// ```
@MainActor
public protocol PageFreezePolicy: AnyObject {
    /// `page` is hidden and awake from now on: it hid, or a call or push from the host thawed it or
    /// reached it while hidden. Its grace starts again.
    ///
    /// - Parameter page: The hidden page; held weakly by the policy.
    func hiddenPageWoke(_ page: PageWebView)

    /// `page` shows again, closed, or left Chromium: it is no longer a page to freeze.
    ///
    /// - Parameter page: The page.
    func pageIsNoLongerHidden(_ page: PageWebView)
}
