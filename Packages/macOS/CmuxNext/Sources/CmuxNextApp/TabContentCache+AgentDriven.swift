import CmuxNextBrowser
import CmuxNextDaemon
import Foundation

/// Saved passwords are not filled into a page an agent drives
/// (plans/cmux-next/browser.md, "Secure sign-in"): an automated click counts
/// as a user gesture, which would let page script, and so the agent, read
/// the filled value. The mark belongs to the tab, so the page that replaces
/// a hibernated or deferred one keeps it (`install`).
extension TabContentCache {
    /// Called by every agent entry point before it acts on tab `key`'s page. Never cleared while the tab lives.
    func markAgentDriven(_ key: String) {
        agentDrivenTabs.insert(key)
        browsers[key]?.tab.markAgentDriven()
    }

    /// Replaces `key`'s live page with a new Chromium page for the same URL,
    /// marked before it exists: nothing filled into the old page, and no
    /// `window.opener` or `window.open` handle to another window, carries
    /// over. The old page leaves the cache at once, so no agent operation can
    /// reach it while the new one loads (unlike a reload, which keeps the old
    /// document until the new one commits).
    func rebuildForAgent(_ key: String) {
        guard let page = browsers[key]?.tab else { return }
        // A page with no URL yet starts over blank.
        reroute(key, to: page.state.url ?? URL(string: "about:blank")!)
        // `reroute` makes nothing while a page is already being made, or
        // without a record; the old page goes regardless.
        if let entry = browsers.removeValue(forKey: key) {
            browserTabs.untrack(key)
            entry.close()
        }
    }

    /// A tab an agent asked for (`openBrowser` from the CLI, MCP or a
    /// script) is marked before its page exists, so its first page load
    /// never fills a saved password. When the page already exists by the time
    /// the tab arrives, the agent's first operation rebuilds it instead.
    func markAgentDriven(surface: SurfaceID) { agentDrivenSurfaces.insert(surface) }

    func claimAgentDriven(surface: SurfaceID, key: String) {
        guard agentDrivenSurfaces.remove(surface) != nil, browsers[key] == nil else { return }
        agentDrivenTabs.insert(key)
    }
}
