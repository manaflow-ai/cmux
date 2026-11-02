import CmuxNextActions
import AppKit
import CmuxNextAgentPane
import CmuxNextPages
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
        // A file or preview the person clicks in the chat opens beside it (LinkOpener,
        // `layout.linkPlacement`), never over the chat; the external editor keeps its own path.
        view.model.onOpenFile = { [weak pane] url, target in
            guard let pane else { return false }
            // A quote from the file's viewer comes back to this chat (viewer-comments-DESIGN.md).
            pane.services.chatQuoteOpeners.noteOpened(url, byAgentTab: key)
            if target == .tab { return pane.services.linkOpener.openFile(url, from: pane) }
            return pane.services.registry.openAgentFile(path: url.path, target: target, pane: pane.paneKey)
        }
        view.model.onOpenPreview = { [weak pane] url in
            guard let pane else { return false }
            // A clicked link's tab, the hover card's Open: as a link clicked in the chat (LinkOpener.openWeb).
            if url.scheme == "http" || url.scheme == "https" { return pane.services.linkOpener.openWeb(url, from: pane, background: false, reusesTab: true) }
            return pane.services.registry.openAgentPreview(url, pane: pane.paneKey)
        }
        if !view.model.hasPainted { drawLastPage(key, until: view) }
        if view.model.newTab != nil { AgentPaneNewTabFrame.shared.capture(view, in: pane.view.contentHost) }
        if view.model.newTab != nil { BenchSpans.mark(view.superview is PageOffscreenParking ? "newTab.show.parked" : "newTab.show") }
        if view.model.hasPainted, view.superview is PageOffscreenParking { coverMove(of: view) }
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
        // From the tab's record, so a tab its launch defers (no view yet) is judged as what it is.
        let newTab = view.map { $0.model.newTab != nil } ?? pane.services.agentTabs.isNewTabPage(key)
        // A New Tab page with no saved image of its own draws the last New Tab frame (cx-ec99), unless
        // it shows in Chromium: that page draws over the frame as it comes in, both seen at once.
        let newTabFrame = { view?.model.newTab == nil || view?.pageDrawsOverCovers == true ? nil : AgentPaneNewTabFrame.shared.image(size: paneView.contentHost.bounds.size, appearance: Self.appearance(of: paneView)) }
        let saved = { images.takeCovering(key, newTab: newTab, size: paneView.contentHost.bounds.size, appearance: Self.appearance(of: paneView), in: paneView) }
        let image = { saved() ?? newTabFrame() }
        if paneView.launchImageView == nil, let image = image() { paneView.showLaunchImage(image) }
        guard let imageView = paneView.launchImageView, let view else { return }
        view.showsLoadingState = false
        // The image's limit takes it only once the page has drawn. A chat read at launch can take
        // longer than that limit (acpmux's attach, and the page holds its first frame until the
        // chat is read), and the frame it would hand the pane to is empty.
        paneView.launchImageMayClear = { [weak view] in view?.model.hasPainted ?? true }
        paneView.onLaunchImageCleared = { [weak view] in
            if let view, view.model.newTab == nil { view.showsLoadingState = true }
        }
        // Once the page has faded in over it (`AgentPaneLoadingView.leave`).
        view.loadingView.whenRevealed { [weak paneView, weak imageView] in
            guard let imageView else { return }
            paneView?.clearLaunchImage(ifShowing: imageView)
        }
        view.whenPagePainted { [weak paneView, weak imageView] in
            guard let imageView else { return }
            paneView?.clearLaunchImage(ifShowing: imageView)
        }
    }

    /// A parked spare taken into this pane draws nothing until WebKit renders it in its new place
    /// (2-5 frames of an empty pane after Cmd-N, cx-21zkz): the New Tab frame shows under it, and
    /// the page stays clear, until its next frame there. Its own parked frame first, at the size it shows at.
    private func coverMove(of view: AgentPaneView) {
        let paneView = pane.view, appearance = Self.appearance(of: paneView)
        let size = pane.services.newTabSpares.openingSize(of: view) ?? paneView.contentHost.bounds.size
        // Only a frame at that size (none for a pane not laid out), and the page stays clear until it drew there, cover or
        // not: a page shown at its parked size (a split pane's) shifted as it laid out again (Leo 2026-10-20).
        let own = view.redraw.takeRememberedFrame(size: size, appearance: appearance)
        let image = size == .zero || paneView.launchImageView != nil || view.pageDrawsOverCovers ? nil : own ?? AgentPaneNewTabFrame.shared.image(size: size, appearance: appearance)
        BenchSpans.mark(image == nil ? "newTab.cover.none \(size) \(String(describing: appearance))" : own != nil ? "newTab.cover.own" : "newTab.cover")
        // The image's deadline shows the page too, should its frame never be reported.
        if let image {
            paneView.showLaunchImage(image)
            paneView.launchImageInvokesResizeCallback = false
            paneView.onLaunchImageCleared = { [weak view] in view?.revealMovedPage() }
        }
        let imageView = image == nil ? nil : paneView.launchImageView
        view.hideMovedPage { [weak paneView, weak imageView] in
            BenchSpans.mark("newTab.cover.cleared")
            if let imageView { paneView?.clearLaunchImage(ifShowing: imageView) }
        }
    }

    private static func appearance(of view: NSView) -> NSAppearance.Name? {
        view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
    }
}
