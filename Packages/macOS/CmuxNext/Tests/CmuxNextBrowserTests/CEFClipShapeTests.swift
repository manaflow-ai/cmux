import AppKit
import Testing
@testable import CmuxNextBrowser

/// The Chromium page mask (`CEFHostView.cmuxClipPath`): rounded pane
/// corners and the window's own rounded corners.
@Suite struct CEFClipShapeTests {
    typealias Rounded = CEFClipShape.RoundedRect

    /// A 2x2 split in an 800x600 window (host coordinates = window
    /// coordinates here, origin bottom-left like `CEFHostView`): the page
    /// host of each pane is its content rect below a 28 pt tab strip.
    private let window = CGRect(x: 0, y: 0, width: 800, height: 600)
    private let windowRadius: CGFloat = 16

    private func contains(_ path: CGPath, _ x: CGFloat, _ y: CGFloat) -> Bool {
        path.contains(CGPoint(x: x, y: y))
    }

    @Test func bottomRightPageIsClippedByTheWindowCornerWithoutPadding() throws {
        // Padding 0, radius 0: the pane is square, the window is not.
        let host = CGRect(x: 400, y: 0, width: 400, height: 272)
        let clips = [Rounded(rect: window, radius: windowRadius)]
        let path = try #require(CEFClipShape.path(bounds: host, clips: clips))
        #expect(!contains(path, 799.5, 0.5))   // the corner that stuck out
        #expect(contains(path, 790, 20))       // inside the arc
        #expect(contains(path, 600, 100))
        #expect(contains(path, 400.5, 0.5))    // interior corner stays square
    }

    @Test func topLeftPageInAMiddleOfTheWindowNeedsNoMaskWithoutPaneCorners() {
        // Tab strip above, split neighbors right and below: no window corner.
        let host = CGRect(x: 180, y: 301, width: 219, height: 271)
        #expect(CEFClipShape.path(bounds: host, clips: [Rounded(rect: window, radius: windowRadius)]) == nil)
    }

    @Test func roundedPaneCornersClipOnlyTheCornersInsideTheHost() throws {
        // Pane content rect (padding 2, radius 6) around a host below the
        // strip: the host holds the pane's bottom corners only.
        let pane = CGRect(x: 402, y: 2, width: 396, height: 296)
        let host = CGRect(x: 402, y: 2, width: 396, height: 268)
        let path = try #require(CEFClipShape.path(bounds: host, clips: [Rounded(rect: pane, radius: 6)]))
        #expect(!contains(path, 402.3, 2.3))
        #expect(!contains(path, 797.7, 2.3))
        #expect(contains(path, 402.3, 269.7))   // top corners are under the strip: square
        #expect(contains(path, 797.7, 269.7))
        #expect(contains(path, 600, 100))
    }

    @Test func paneAndWindowCornersCombine() throws {
        let pane = CGRect(x: 402, y: 2, width: 396, height: 296)
        let host = CGRect(x: 402, y: 2, width: 396, height: 268)
        let path = try #require(CEFClipShape.path(bounds: host, clips: [
            Rounded(rect: pane, radius: 6), Rounded(rect: window, radius: windowRadius),
        ]))
        // A point inside the pane's arc but outside the window's arc.
        #expect(!contains(path, 795.8, 4.3))
        #expect(contains(path, 405, 8))
    }

    @Test func squareClipsGiveNoPath() {
        let host = CGRect(x: 0, y: 0, width: 400, height: 300)
        #expect(CEFClipShape.path(bounds: host, clips: []) == nil)
        #expect(CEFClipShape.path(bounds: host, clips: [Rounded(rect: host, radius: 0)]) == nil)
        #expect(CEFClipShape.path(bounds: .zero, clips: [Rounded(rect: host, radius: 8)]) == nil)
    }

    @Test func radiusIsCappedAtHalfTheShorterSide() throws {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 10)
        let path = try #require(CEFClipShape.path(bounds: rect, clips: [Rounded(rect: rect, radius: 40)]))
        #expect(contains(path, 50, 5))
        #expect(!contains(path, 0.5, 0.5))
    }

    @MainActor
    @Test func windowCornerRadiusIsZeroForBorderlessWindows() {
        let borderless = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
        #expect(CEFClipShape.windowCornerRadius(borderless) == 0)
        let titled = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        #expect(CEFClipShape.windowCornerRadius(titled) > 0)
    }

    @MainActor
    @Test func clipsCollectRoundedAncestorsInHostCoordinates() {
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        let clip = NSView(frame: CGRect(x: 4, y: 4, width: 492, height: 392))
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.layer?.cornerRadius = 6
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 492, height: 364))
        root.addSubview(clip)
        clip.addSubview(host)
        let clips = CEFClipShape.clips(around: host)
        #expect(clips == [Rounded(rect: CGRect(x: 0, y: 0, width: 492, height: 392), radius: 6)])
    }
}
