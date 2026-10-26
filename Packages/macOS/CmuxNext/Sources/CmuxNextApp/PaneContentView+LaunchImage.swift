import AppKit
import CmuxNextLaunch
import CmuxNextWakeups

extension PaneContentView {
    /// Draws `image` (an agent page's last frame, `AgentPaneLaunchImages`)
    /// under the content, top-left at its point size, until the live page
    /// paints: an agent page is transparent until then, so the pane never
    /// shows empty at launch. While it shows, `hold` holds startup open.
    func showLaunchImage(_ image: NSImage, hold: LaunchImageHold) {
        // Before the old image goes, so a replaced image never ends the hold for a turn.
        hold.began()
        clearLaunchImage()
        let view = NSView(frame: contentHost.bounds)
        view.wantsLayer = true
        view.autoresizingMask = [.width, .height]
        view.layer?.contentsGravity = .topLeft
        view.layer?.contentsScale = image.recommendedLayerContentsScale(window?.backingScaleFactor ?? 2)
        view.layer?.contents = image.layerContents(forContentsScale: view.layer?.contentsScale ?? 2)
        contentHost.addSubview(view, positioned: .below, relativeTo: nil)
        launchImageView = view
        launchImageHold = hold
        DebugTimings.markLaunch("agent_pane.launch_image_shown")
        launchImageDeadline.schedule(after: LaunchImageHold.imageLimit) { @MainActor [weak self] in self?.clearLaunchImage(.visiblePaneTimedOut) }
    }

    /// Removes the launch image (the page painted, or the pane shows another tab).
    ///
    /// - Parameter reason: Why it goes, for the startup ref the last image ends.
    func clearLaunchImage(_ reason: StartupInProgressRef.Reason = .visiblePaneLoadedIdle) {
        launchImageDeadline.cancel()
        if let launchImageView {
            DebugTimings.markLaunch("agent_pane.launch_image_cleared")
            launchImageView.removeFromSuperview()
            self.launchImageView = nil
            launchImageHold?.ended(reason)
            launchImageHold = nil
        }
        // A page that has not painted when the image goes (its limit) shows its loading state.
        let cleared = onLaunchImageCleared
        onLaunchImageCleared = nil
        cleared?()
    }
}
