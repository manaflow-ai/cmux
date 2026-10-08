import AppKit

/// How long a launch image may stay when its page never reports a first frame.
let paneLaunchImageLimit: Duration = .seconds(3)

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
        DebugTimings.markLaunch("agent_pane.launch_image_shown")
        launchImageDeadline.schedule(after: paneLaunchImageLimit) { @MainActor [weak self] in self?.clearLaunchImage() }
    }

    /// Removes the launch image (the page painted, or the pane shows another tab).
    func clearLaunchImage() {
        launchImageDeadline.cancel()
        if launchImageView != nil { DebugTimings.markLaunch("agent_pane.launch_image_cleared") }
        launchImageView?.removeFromSuperview()
        launchImageView = nil
        // A page that has not painted when the image goes (its limit) shows its loading state.
        let cleared = onLaunchImageCleared
        onLaunchImageCleared = nil
        cleared?()
    }
}
