import AppKit
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// A window that reports a 1x backing scale whatever display it opens on.
private final class OneXWindow: NSWindow {
    override var backingScaleFactor: CGFloat { 1 }
}

/// The omnibar's height lies on the pixel grid of the window it draws in, not of the screen it was built for. Spacious's
/// bar is 37.5 pt: 38 pt on a 1x display, 37.5 at 2x. A bar is built before it has a window, at the main screen's scale,
/// and kept that height when it joined a window of another scale: on the fleet's 1x display it drew 37 pt
/// (OmnibarDensityTests `nothingClipsOrOverlaps` Spacious), and a window moved from a Retina display to a 1x one kept
/// its bar half a point off the grid.
@MainActor @Suite(.serialized, .closesItsWindows) struct OmnibarBarWindowScaleTests {
    @Test(arguments: [1, 2] as [CGFloat])
    func theBarSnapsToItsWindowsPixels(scale: CGFloat) throws {
        try DensityTokens.$scoped.withValue(DensityPreset.spacious.tokens) {
            let bar = AddressBarView()
            let frame = NSRect(x: 0, y: 0, width: 900, height: 120)
            let window: NSWindow = scale == 1
                ? OneXWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
                : TwoXWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            defer { window.closeAfterTest() }
            let content = try #require(window.contentView)
            content.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
                bar.widthAnchor.constraint(equalToConstant: 520),
                bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            ])
            content.layoutSubtreeIfNeeded()
            let want = OmnibarStyle.barHeight(scale: scale)
            #expect(OmnibarStyle.barHeight == 37.5, "Spacious's bar is 37.5 pt (this test needs a half-point bar)")
            #expect(bar.frame.height == want,
                    "a \(OmnibarStyle.barHeight) pt bar in a \(scale)x window is \(bar.frame.height) pt, want \(want) (main screen \(NSScreen.main?.backingScaleFactor ?? 0)x)")
        }
    }
}
