import AppKit
import CmuxNextBrowser
import CmuxNextLaunch

extension LaunchImageHold {
    /// The app's one hold, shared by the panes that show launch images and the work that waits for them.
    static let shared = LaunchImageHold()
}

extension PaneContentView {
    /// Draws `image` (an agent page's last frame, `AgentPaneLaunchImages`)
    /// under the content, top-left at its point size, until the live page
    /// paints: an agent page is transparent until then, so the pane never
    /// shows empty at launch.
    func showLaunchImage(_ image: NSImage) {
        clearLaunchImage()
        let view = NSView(frame: contentHost.bounds)
        view.wantsLayer = true
        view.autoresizingMask = [.width, .height]
        view.layer?.contentsGravity = .topLeft
        view.layer?.contentsScale = image.recommendedLayerContentsScale(window?.backingScaleFactor ?? 2)
        view.layer?.contents = image.layerContents(forContentsScale: view.layer?.contentsScale ?? 2)
        contentHost.addSubview(view, positioned: .below, relativeTo: nil)
        launchImageView = view
        LaunchImageHold.shared.began()
        DebugTimings.markLaunch("agent_pane.launch_image_shown")
        launchImageDeadline.schedule(after: LaunchImageHold.imageLimit) { @MainActor [weak self] in self?.clearLaunchImage() }
    }

    /// Removes the launch image (the page painted, or the pane shows another tab).
    func clearLaunchImage() {
        launchImageDeadline.cancel()
        if launchImageView != nil { DebugTimings.markLaunch("agent_pane.launch_image_cleared") }
        if let launchImageView {
            launchImageView.removeFromSuperview()
            self.launchImageView = nil
            LaunchImageHold.shared.ended()
        }
        // A page that has not painted when the image goes (its limit) shows its loading state.
        let cleared = onLaunchImageCleared
        onLaunchImageCleared = nil
        cleared?()
    }
}

extension PaneController {
    /// The startup pane ref's content signal (`VisiblePaneRefs`): a terminal's first content, a page's
    /// first load ended, an agent page's first paint (task 105 makes each loaded-idle).
    var launchState: VisiblePaneRefs.PaneState {
        guard stripModel.selectedID != nil else { return .loadedIdle }
        let loaded: Bool = switch currentContent {
        case nil: false
        case .terminal(let entry)?: !showsLiveTerminal || entry.session.diagnostics.hasContent
        case .browser(let entry)?: StartupReferences.VisiblePage(entry) == .idle
        case .agent(let view)?: view.model.hasPainted
        case .page?, .placeholder?, .notice?, .conversation?: true
        }
        return loaded ? .loadedIdle : .loading
    }
}

extension StartupReferences.VisiblePage {
    /// A shown page: idle once a load ended in it (finished, stopped or failed) or its process
    /// ended, or when it is a stand-in that loads nothing until the person starts it.
    init(page state: BrowserTabState, loadsNothing: Bool) {
        self = loadsNothing || state.hasEndedLoad || state.processExit != nil ? .idle : .waiting
    }

    /// A shown browser tab's page.
    init(_ entry: BrowserEntry) {
        self.init(page: entry.tab.state, loadsNothing: entry.tab is DeferredBrowserTab || entry.tab is HibernatedBrowserTab)
    }
}
