import AppKit
import CmuxNextAgentPane
import CmuxNextWakeups

/// How long a launch image may stay when its page never reports a first frame.
let paneLaunchImageLimit: Duration = .seconds(3)

extension PaneContentView {
    /// Draws `image` (an agent page's last frame, `AgentPaneLaunchImages`)
    /// under the content, top-left at its point size, until the live page
    /// paints: an agent page is transparent until then, so the pane never
    /// shows empty at launch.
    func showLaunchImage(_ image: NSImage) {
        // This image's hold begins before the last one's ends: a swap (the New Tab frame, then the saved
        // page) never lets deferred launch work in between.
        LaunchImageHold.shared.began()
        clearLaunchImage()
        let view = NSView(frame: contentHost.bounds)
        view.wantsLayer = true
        view.autoresizingMask = [.width, .height]
        view.layer?.contentsGravity = .topLeft
        view.layer?.contentsScale = image.recommendedLayerContentsScale(window?.backingScaleFactor ?? 2)
        view.layer?.contents = image.layerContents(forContentsScale: view.layer?.contentsScale ?? 2)
        contentHost.addSubview(view, positioned: .below, relativeTo: nil)
        launchImageView = view
        DebugTimings.markLaunch("agent_pane.launch_image_shown")
        launchImageDeadline.schedule(after: paneLaunchImageLimit) { @MainActor [weak self] in self?.clearLaunchImage() }
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

    /// Draws tab `key`'s last page under the content until `view`'s live page paints
    /// (`AgentPaneLaunchImages`), so a relaunch never shows an empty agent pane. A released page's
    /// frame shows at once. Otherwise the pane first shows what it shows with no saved page (its
    /// loading state, or `newTabFrame`), and the page the last quit saved follows once it is read and
    /// decoded off the main thread, if the pane still shows the tab (`showing`), the tab's page
    /// (`page`) has not painted, and nothing else has covered the pane since. While an image shows,
    /// the page's loading state stays off above it, until the image goes.
    ///
    /// - Returns: The read of the saved page, when one runs (tests await it).
    @discardableResult
    func drawLastPage(_ key: String, from images: AgentPaneLaunchImages, on work: BackgroundWork, until view: AgentPaneView?,
                      newTabFrame: () -> NSImage?, showing: @escaping @MainActor @Sendable () -> Bool,
                      page: @escaping @MainActor @Sendable () -> AgentPaneView?) -> Task<Void, Never>? {
        guard launchImageView == nil else {
            holdLoadingState(of: view)
            return nil
        }
        let held = images.take(key, size: contentHost.bounds.size, appearance: effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]))
        if let image = held ?? newTabFrame() { showLaunchImage(image) }
        holdLoadingState(of: view)
        guard held == nil, images.mayHaveSaved(key) else { return nil }
        let placeholder = launchImageView
        // task-owner: one off-main read of the tab's saved page; ends when it does.
        return Task { [weak self] in
            guard let image = await images.takeSaved(key, on: work), let self, showing(), launchImageView === placeholder else { return }
            let view = page()
            guard view?.model.hasPainted != true else { return }
            showLaunchImage(image)
            holdLoadingState(of: view)
        }
    }

    /// Over its last page's image, `view` draws no loading state until the image goes; the image goes
    /// once the page has faded in over it (`AgentPaneLoadingView.leave`).
    private func holdLoadingState(of view: AgentPaneView?) {
        guard launchImageView != nil, let view else { return }
        view.showsLoadingState = false
        onLaunchImageCleared = { [weak view] in
            if let view, view.model.newTab == nil { view.showsLoadingState = true }
        }
        view.loadingView.whenRevealed { [weak self] in self?.clearLaunchImage() }
    }
}
