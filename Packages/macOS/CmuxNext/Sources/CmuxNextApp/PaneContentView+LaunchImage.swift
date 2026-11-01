import AppKit

/// How long a launch image may stay once the page it stands in for has painted. It is not the
/// bound on a page that never reports a first frame: such a page keeps its frame past this
/// (`launchImageMayClear`), because taking it leaves the pane empty. What bounds that case is
/// `AgentPaneLoadingView`'s give-up, which shows the page as it is after two unpainted checks
/// (2 x `paintCheckInterval`, about 8 s). Deferred launch work has its own bound either way:
/// `LaunchImageHold`'s backstop runs the waiters at this limit plus a second.
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
        launchImageSizes = [contentHost.bounds.size, image.size]
        launchImageInvokesResizeCallback = true
        LaunchImageHold.shared.began()
        DebugTimings.markLaunch("agent_pane.launch_image_shown")
        launchImageDeadline.schedule(after: limit) { @MainActor [weak self] in
            guard let self else { return }
            // The frame stands in for a page that has not drawn yet, so the limit alone does not
            // take it: dropping it here used to hand the pane its empty loading state while the
            // page was still inside its own first-paint budget, which is a chat that draws, goes
            // dark for several seconds, then comes back (Leo 2026-10-22). What takes it instead is
            // the page drawing over it, or the pane giving up on a page that never reports and
            // showing it as it is (`AgentPaneLoadingView`), both of which end on the page. The
            // give-up is still the earlier of the two budgets (about 8 s against the page's own
            // ~10 s `CHAT_DRAW_HOLD_MS` after its handshake), so a daemon slow enough to miss it
            // reveals the page while it is itself still blank. That narrows Leo's dark gap rather
            // than closing it; closing it means moving one of the two budgets.
            guard launchImageMayClear?() ?? true else { return }
            clearLaunchImage()
        }
    }

    /// A page's delayed reveal removes only the frame it stood behind. Another tab may have
    /// installed its own frame in this pane while that page was still loading.
    func clearLaunchImage(ifShowing image: NSView) {
        guard launchImageView === image else { return }
        clearLaunchImage()
    }

    /// Removes the launch image (the page painted, or the pane shows another tab).
    func clearLaunchImage(invokeCallback: Bool = true) {
        launchImageDeadline.cancel()
        // The next frame says for itself whether its limit may take it; `showLaunchImage` clears
        // first, so a frame held over a painted page never inherits a relaunch's answer.
        launchImageMayClear = nil
        if launchImageView != nil { DebugTimings.markLaunch("agent_pane.launch_image_cleared") }
        if let launchImageView {
            launchImageView.removeFromSuperview()
            self.launchImageView = nil
            launchImageSizes = []
            LaunchImageHold.shared.ended()
        }
        // A page that has not painted when the image goes (its limit) shows its loading state.
        guard invokeCallback else {
            onLaunchImageCleared = nil
            return
        }
        let cleared = onLaunchImageCleared
        onLaunchImageCleared = nil
        cleared?()
    }
}
