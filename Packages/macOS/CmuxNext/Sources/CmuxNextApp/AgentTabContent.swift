import CmuxNextActions
import CmuxNextAgentPane
import Foundation

/// An agent tab's content in `pane`, with its changed files opening beside
/// it: in a new tab of this pane (the file preview is a browser page on a
/// `file://` URL until the preview surface lands), or in the editor app. Both
/// go through the `file.open` action, the path the palette and `cmux file
/// open` take. A turn's local web page opens in a new browser tab of this
/// pane through `openBrowser`. Its own type, not a PaneController
/// extension: PaneController stays under the god-type budget.
@MainActor
struct AgentTabContent {
    let pane: PaneController

    func content(_ key: String) -> TabContent? {
        let services = pane.services
        let focused = pane.workspace?.focus.state.pane
        let deferred = services.agentTabs.deferAtLaunch(
            key, reveal: services.launchReveal, focusedPane: focused, pane: pane.paneKey,
            focusedDraws: focused.flatMap { key in pane.workspace?.panes.values.first { $0.paneKey == key } }?.showsLiveTerminal ?? false
        ) { [weak pane] in
            if let pane, pane.currentTabKey == key { pane.showSelected() }
        }
        if deferred {
            drawLastPage(key, until: nil)
            return nil
        }
        guard let view = services.agentTabs.view(for: key) else {
            return services.agentTabs.notice(for: key).map(TabContent.notice)
        }
        // Set on each show, so a tab moved to another pane opens files there.
        view.model.onOpenFile = { [weak pane] url, target in
            guard let pane else { return false }
            return pane.services.registry.openAgentFile(path: url.path, target: target, pane: pane.paneKey)
        }
        view.model.onOpenPreview = { [weak pane] url in
            guard let pane else { return false }
            return pane.services.registry.openAgentPreview(url, pane: pane.paneKey)
        }
        if !view.model.hasPainted { drawLastPage(key, until: view) }
        AgentReplySites(services: services).wire(view.model.replyLinks)
        return .agent(view)
    }

    /// The tab's page from the last quit, under the pane until `view`'s
    /// live page paints (`AgentPaneLaunchImages`): a relaunch never shows
    /// an empty agent pane. The image is the pane's first frame, so the
    /// pane's own loading state stays off above it until the image goes.
    private func drawLastPage(_ key: String, until view: AgentPaneView?) {
        let paneView = pane.view
        if paneView.launchImageView == nil, let image = pane.services.agentTabs.launchImages.take(key) { paneView.showLaunchImage(image) }
        guard paneView.launchImageView != nil, let view else { return }
        view.showsLoadingState = false
        paneView.onLaunchImageCleared = { [weak view] in view?.showsLoadingState = true }
        view.model.whenPainted { [weak paneView] in paneView?.clearLaunchImage() }
    }
}
