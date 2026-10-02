import AppKit
import CmuxNextActions
import CmuxNextAgentPane

/// An agent tab's changed files open beside it: in a new tab of this pane
/// (the file preview is a browser page on a `file://` URL until the preview
/// surface lands), or in the editor app. Both go through the `file.open`
/// action, the path the palette and `cmux file open` take.
extension PaneController {
    func agentContent(_ key: String) -> TabContent? {
        guard let view = services.agentTabs.view(for: key) else { return nil }
        // Set on each show, so a tab moved to another pane opens files there.
        view.model.onOpenFile = { [weak self] url, target in self?.openAgentFile(url, target) ?? false }
        return .agent(view)
    }

    /// False when the file does not open. The check runs here first so the
    /// page hears a refusal; an editor that fails after it starts opening is
    /// not reported back.
    private func openAgentFile(_ url: URL, _ target: AgentPaneFileTarget) -> Bool {
        guard (try? AgentPaneFileOpening.plan(path: url.path, target: target)) != nil else { return false }
        let invocation = ActionInvocation(
            target: ActionTargetRef(kind: .pane, id: paneKey),
            arguments: ["path": .string(url.path), "where": .string(target.rawValue)]
        )
        return services.registry.perform(.fileOpen, invocation: invocation)
    }
}
