import CmuxNextActions
import AppKit
import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextWakeups
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
            // A file ref's page opens beside the chat (ChatBeside); Command-click, a new tab here.
            if target == .tab, !ChatBeside.keepsOldPlace, ChatBeside(services: pane.services).open(.file(url), beside: key) { return true }
            return pane.services.registry.openAgentFile(path: url.path, target: target, pane: pane.paneKey)
        }
        // A link, a PR's among them, opens in the in-app browser beside the chat; Command-click, the
        // default browser, as every link did before.
        view.openURL = { [weak pane] url in
            if ChatBeside.keepsOldPlace || pane.map({ ChatBeside(services: $0.services).open(.url(url), beside: key) }) != true {
                NSWorkspace.shared.openInBackground(url)
            }
        }
        view.model.onOpenPreview = { [weak pane] url in
            guard let pane else { return false }
            return pane.services.registry.openAgentPreview(url, pane: pane.paneKey)
        }
        if !view.model.hasPainted { drawLastPage(key, until: view) }
        if view.model.newTab != nil { rememberNewTabFrame(of: view) }
        if view.model.newTab != nil { BenchSpans.mark(view.superview is NewTabSpareParking ? "newTab.show.parked" : "newTab.show") }
        if view.model.hasPainted, view.superview is NewTabSpareParking { coverMove(of: view) }
        AgentReplySites(services: services).wire(view.model.replyLinks)
        return .agent(view)
    }

    /// The tab's page from the last quit, under the pane until `view`'s
    /// live page paints (`AgentPaneLaunchImages`): a relaunch never shows
    /// an empty agent pane. The image is the pane's first frame, so the
    /// pane's own loading state stays off above it until the image goes.
    private func drawLastPage(_ key: String, until view: AgentPaneView?) {
        let paneView = pane.view
        let images = pane.services.agentTabs.launchImages
        // A New Tab page with no saved image of its own draws the last New Tab frame (cx-ec99).
        let newTabFrame = { view?.model.newTab == nil ? nil : images.newTabFrame(size: paneView.contentHost.bounds.size, appearance: Self.appearance(of: paneView)) }
        let image = { images.take(key, size: paneView.contentHost.bounds.size, appearance: Self.appearance(of: paneView)) ?? newTabFrame() }
        if paneView.launchImageView == nil, let image = image() { paneView.showLaunchImage(image) }
        guard paneView.launchImageView != nil, let view else { return }
        view.showsLoadingState = false
        paneView.onLaunchImageCleared = { [weak view] in
            if let view, view.model.newTab == nil { view.showsLoadingState = true }
        }
        // Once the page has faded in over it (`AgentPaneLoadingView.leave`).
        view.loadingView.whenRevealed { [weak paneView] in paneView?.clearLaunchImage() }
    }

    /// A parked spare taken into this pane draws nothing until WebKit renders it in its new place
    /// (2-5 frames of an empty pane after Cmd-N, cx-21zkz): the New Tab frame shows under it, and
    /// the page stays clear, until its next frame there. Its own parked frame first, at the size it shows at.
    private func coverMove(of view: AgentPaneView) {
        let paneView = pane.view, appearance = Self.appearance(of: paneView)
        let size = pane.services.newTabSpares.openingSize(of: view) ?? paneView.contentHost.bounds.size
        let own = view.redraw.takeRememberedFrame(size: size, appearance: appearance)
        guard paneView.launchImageView == nil, let image = own ?? pane.services.agentTabs.launchImages.newTabFrame(size: size, appearance: appearance)
        else { return BenchSpans.mark("newTab.cover.none \(size) \(String(describing: appearance))") }
        BenchSpans.mark(own != nil ? "newTab.cover.own" : "newTab.cover")
        paneView.showLaunchImage(image)
        // The image's deadline shows the page too, should its frame never be reported.
        paneView.onLaunchImageCleared = { [weak view] in view?.revealMovedPage() }
        view.hideMovedPage { [weak paneView] in
            BenchSpans.mark("newTab.cover.cleared")
            paneView?.clearLaunchImage()
        }
    }

    /// `view` 400 ms after it painted here (its chats and chips in), clear areas left clear (the pane
    /// paints under it): what the next New Tab page draws until it paints (cx-ec99). The first page's
    /// first paint on the theme's color showed under each Cmd-T: no chats, no model (Leo 2026-10-13).
    private func rememberNewTabFrame(of view: AgentPaneView) {
        let images = pane.services.agentTabs.launchImages
        view.model.whenPainted { [weak view, weak paneView = pane.view] in
            let settle = DemandTimer(owner: "newTab.frame.settle")
            settle.schedule(after: .milliseconds(400)) { @MainActor in
                withExtendedLifetime(settle) {}
                guard let view, let paneView, view.model.newTab != nil, view.isDescendant(of: paneView.contentHost) else { return }
                let size = paneView.contentHost.bounds.size, appearance = Self.appearance(of: paneView)
                guard size != .zero, let image = try? await view.webView.takeSnapshot(configuration: nil) else { return }
                images.rememberNewTabFrame(image, size: size, appearance: appearance)
            }
        }
    }

    private static func appearance(of view: NSView) -> NSAppearance.Name? {
        view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
    }
}
