import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Testing

/// Leo, 2026-11-23, Frosted on a 2x display: "it went only to the bottom left", "as in it didnt
/// fill the whole thing" (cmux#51381). The still art takes a blurred copy since #51475; a video or
/// living wallpaper kept a live `CIAffineClamp` + `CIGaussianBlur` layer filter, which on a Retina
/// backing covered the bottom half, then only the bottom-left quadrant after a resize
/// (scripts/measure/frosted-art-2x.sh, on a MacBook's built-in Retina display: 0/0/89/91 % then
/// 0/0/79/0 % per quadrant; the blur alone on a view past a clip: 100 % everywhere, no rim).
/// `CALayer.render(in:)` ignores layer filters, so these pin the setup the measure proved.
@MainActor @Suite struct FrostedLiveWallpaperBlurTests {
    /// A video or living wallpaper changes every frame, so it keeps a live blur: the blur alone (the
    /// clamp before it was what filled only the bottom left at 2x), on a view that runs the blur's
    /// reach past every edge of a clip, so no fading rim shows. Off, it sits at the clip's bounds.
    @Test func liveWallpapersBlurWithoutAClampPastTheClip() {
        let view = WindowMaterialView(frame: NSRect(x: 0, y: 0, width: 400, height: 300),
                                      images: BackdropImageStore(maxPixelSize: 64), videos: BackdropVideoPlayers())
        var input = ThemeInput.ghosttyDefault
        input.backgroundBlur = 20
        view.apply(WindowBackdrop(ThemeTokens.derive(from: input), selection: .art(.vanGoghStarryNight)), tint: .black)
        #expect(view.liveArtClip.layer?.masksToBounds == true)
        for live in [view.videoView as NSView, view.shaderView as NSView] {
            let names = (live.layer?.filters as? [CIFilter])?.map(\.name) ?? []
            #expect(names == ["CIGaussianBlur"], "\(live): \(names)")
            #expect(live.superview === view.liveArtClip)
            #expect(live.frame == view.liveArtClip.bounds.insetBy(dx: -60, dy: -60))
        }
        // The outset follows a resize.
        view.setFrameSize(NSSize(width: 900, height: 600))
        #expect(view.videoView.frame == view.liveArtClip.bounds.insetBy(dx: -60, dy: -60))
        input.backgroundBlur = 0
        view.apply(WindowBackdrop(ThemeTokens.derive(from: input), selection: .art(.vanGoghStarryNight)), tint: .black)
        for live in [view.videoView as NSView, view.shaderView as NSView] {
            let filters = live.layer?.filters ?? []
            #expect(filters.isEmpty)
            #expect(live.frame == view.liveArtClip.bounds)
        }
    }
}
