import AppKit
import CmuxNextAgentPane

/// An agent tab's changed files open beside it: in a new tab of this pane
/// (the file preview is a browser page on a `file://` URL until the preview
/// surface lands), or in the editor app. Its git reads go to the local
/// session host (AgentPaneGitReads.swift).
extension PaneController {
    func agentContent(_ key: String) -> TabContent? {
        guard let view = services.agentTabs.view(for: key) else { return nil }
        // Set on each show, so a tab moved to another pane opens files there.
        view.model.onOpenFile = { [weak self] url, target in await self?.openAgentFile(url, target) ?? false }
        // A local session's folder is read by the local session host; the page refuses cloud sessions.
        let git = services.agentGit
        view.model.onGit = { request in try await git.read(request) }
        return .agent(view)
    }

    /// False when the file did not open. A tab the browser refuses says why in
    /// its own notice, so the page hears only that the tab was asked for.
    private func openAgentFile(_ url: URL, _ target: AgentPaneFileTarget) async -> Bool {
        switch target {
        case .tab:
            newBrowserTab(url: url)
            return true
        case .editor:
            guard let app = AgentPaneFileOpen.editorApplication() else { return false }
            return await withCheckedContinuation { opened in
                NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    opened.resume(returning: error == nil)
                }
            }
        }
    }
}
