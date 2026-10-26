public import CmuxNextWakeups

/// A page whose engine reports that only draw (load progress) wait on its tab's node: a hidden tab keeps the latest
/// and applies it when the node shows (plans/cmux-next/chrome-parity/p06-scheduler.md, recipe R-notif: "KVO on WebKit
/// takes the tab node"). Its model (URL, title, history) still follows the engine at once, shown or hidden.
/// A Chromium page follows its node through ``BrowserVisibilityFollowing`` instead.
public protocol BrowserTabNodeAdopting: AnyObject {
    /// Takes `node` (the tab's, `TabContentCache.node(for:)`) from now on, until another one; the page holds it.
    func adoptNode(_ node: VisibilityNode)
}
