import CmuxNextBrowser
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
}
