import CmuxNextActions
import CmuxNextAgentPane
import Foundation

/// An agent tab's changed files open beside it: in a new tab of this pane
/// (the file preview is a browser page on a `file://` URL until the preview
/// surface lands), or in the editor app. Both go through the `file.open`
/// action, the path the palette and `cmux file open` take.
extension PaneController {
    func agentContent(_ key: String) -> TabContent? {
        guard let view = services.agentTabs.view(for: key) else { return nil }
        // Set on each show, so a tab moved to another pane opens files there.
        view.model.onOpenFile = { [weak self] url, target in
            guard let self else { return false }
            return services.registry.openAgentFile(path: url.path, target: target, pane: paneKey)
        }
        return .agent(view)
    }
}
