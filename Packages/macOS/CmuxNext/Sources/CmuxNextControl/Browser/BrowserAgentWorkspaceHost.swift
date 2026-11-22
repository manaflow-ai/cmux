import Foundation

/// Opens an agent's browser tab where the person never sees it arrive: the
/// agents' own workspace (``BrowserAgentWorkspace``), made once and never
/// shown, selected or focused. `browser.page.right` uses it when Home has no
/// column right of the chat, so an agent always gets a page it can drive
/// (navigate, click, read, screenshot) without a new column in the person's
/// layout (Leo, 2026-11-22: "product bug/gap, again", after an agent could not
/// drive a GitHub page because his Home had no right column).
public protocol BrowserAgentWorkspaceHost: Sendable {
    /// Opens a tab of the agent profile at `url` (nil: a blank page) in
    /// workspace `workspace` (its durable key), or, when nil, in a new
    /// workspace named `name` with the key ``BrowserAgentWorkspace/key``.
    /// Nothing is shown or focused; no window switches workspace.
    ///
    /// - Returns: the new tab's public id (`tab_…`) and its workspace's key.
    @MainActor func openAgentTab(url: String?, inWorkspace workspace: String?, named name: String) async throws
        -> (tab: String, workspace: String)
}
