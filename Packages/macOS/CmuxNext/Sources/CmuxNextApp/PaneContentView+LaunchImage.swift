import AppKit

/// How long a launch image may stay when its page never reports a first frame.
let paneLaunchImageLimit: Duration = .seconds(3)

extension PaneContentView {
    /// Draws `image` (an agent page's last frame, `AgentPaneLaunchImages`)
    /// under the content, top-left at its point size, until the live page
    /// paints: an agent page is transparent until then, so the pane never
    /// shows empty at launch.
    func showLaunchImage(_ image: NSImage, limit: Duration = paneLaunchImageLimit) {
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
        launchImageDeadline.schedule(after: limit) { @MainActor [weak self] in
            guard let self else { return }
            // The frame stands in for a page that has not drawn yet, so the limit alone does not
            // take it: dropping it here used to hand the pane its empty loading state while the
            // page was still inside its own first-paint budget, which is a chat that draws, goes
            // dark for several seconds, then comes back (Leo 2026-10-22). What takes it instead is
            // the page drawing over it, or the pane giving up on a page that never reports and
            // showing it as it is (`AgentPaneLoadingView`), both of which end on the page.
            guard launchImageMayClear?() ?? true else { return }
            clearLaunchImage()
        }
    }

    /// Removes the launch image (the page painted, or the pane shows another tab).
    func clearLaunchImage() {
        launchImageDeadline.cancel()
        // The next frame says for itself whether its limit may take it; `showLaunchImage` clears
        // first, so a frame held over a painted page never inherits a relaunch's answer.
        launchImageMayClear = nil
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
