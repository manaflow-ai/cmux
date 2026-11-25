import AppKit
import AVFoundation
import CmuxNextDesignTokens

/// The Desktop Wallpaper (``BackdropSelection/desktop``) as macOS draws it on the window's screen:
/// placed by the screen's Fill, Fit, Stretch or Center, with its fill color around a fitted or
/// centered picture, and reloaded when the window moves to another display.
extension WindowMaterialView {
    /// Places the art (and a video over it) as `desktop` says; every other background fills.
    /// Only what changed is set, so an apply per frame of a resize writes nothing.
    func applyArtFit(_ desktop: DesktopShown?) {
        let fit = desktop?.fit ?? .fill
        let fill = desktop.flatMap { fit.showsFill && $0.fill.count == 3 ? CGColor(srgbRed: $0.fill[0], green: $0.fill[1], blue: $0.fill[2], alpha: 1) : nil } // colour-allow: macOS's own desktop fill color, mirrored
        if let layer = artView.layer, layer.backgroundColor != fill { layer.backgroundColor = fill }
        if let layer = videoView.layer, layer.backgroundColor != fill { layer.backgroundColor = fill }
        // A centered picture keeps its own size: one pixel per backing pixel.
        if fit == .center, let scale = window?.backingScaleFactor, artView.layer?.contentsScale != scale { artView.layer?.contentsScale = scale }
        guard fit != artFit else { return }
        artFit = fit
        // AppKit sets a backing layer's gravity from its placement: both say the same.
        switch fit {
        case .fill:
            artView.layerContentsPlacement = .scaleProportionallyToFill
            artView.layer?.contentsGravity = .resizeAspectFill
            videoView.playerLayer.videoGravity = .resizeAspectFill
        case .fit:
            artView.layerContentsPlacement = .scaleProportionallyToFit
            artView.layer?.contentsGravity = .resizeAspect
            videoView.playerLayer.videoGravity = .resizeAspect
        case .stretch:
            artView.layerContentsPlacement = .scaleAxesIndependently
            artView.layer?.contentsGravity = .resize
            videoView.playerLayer.videoGravity = .resize
        case .center:
            artView.layerContentsPlacement = .center
            artView.layer?.contentsGravity = .center
            // A movie has no size of its own on screen: it fits, as macOS plays an aerial.
            videoView.playerLayer.videoGravity = .resizeAspect
        }
        noteGlassSourceChange()
    }

    /// Whether this view shows the Desktop Wallpaper in a visible window that is not covered:
    /// the desktop watch re-reads every few seconds only while one does.
    var followsDesktopVisibly: Bool {
        guard followsDesktop, let window, window.isVisible else { return false }
        return window.occlusionState.contains(.visible)
    }

    /// The window may be on another display now: the Desktop Wallpaper shows that display's.
    func desktopScreenMayHaveChanged() {
        guard followsDesktop, window?.screen.flatMap(DesktopWallpaperWatch.displayID) != loadedDesktopScreen else { return }
        desktopWallpaperDidChange()
    }
}
