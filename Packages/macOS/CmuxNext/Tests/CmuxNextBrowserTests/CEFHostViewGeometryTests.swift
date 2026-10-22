import AppKit
import Testing
@testable import CmuxNextBrowser

/// Chromium perf (Leo's audit, msg 9136): the fork re-reads `cmuxClipPath`
/// and `cmuxOcclusionRects` on every geometry update, and an ancestor's frame
/// change reaches it once per observed ancestor, so a pane drag asked for the
/// clip many times per frame. Each read built the rounded clip again with
/// CGPath boolean operations. The host builds it only when its inputs
/// (bounds, ancestor clips, strip cutouts) change, and a hidden host asks
/// the fork for no update at all.
@MainActor
@Suite struct CEFHostViewGeometryTests {
    /// A host in a pane with rounded corners, the shape that needs a clip path.
    private func roundedPane() -> (pane: NSView, host: CEFHostView) {
        let pane = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        pane.wantsLayer = true
        pane.layer?.masksToBounds = true
        pane.layer?.cornerRadius = 12
        let host = CEFHostView(frame: pane.bounds)
        pane.addSubview(host)
        return (pane, host)
    }

    @Test func repeatedReadsBuildTheClipOnce() {
        let (_, host) = roundedPane()
        for _ in 0..<20 {
            _ = host.cmuxClipPath()
            _ = host.cmuxOcclusionRects()
        }
        #expect(host.cmuxClipPath() != nil, "the rounded pane clips the page")
        #expect(host.clipShapeBuilds == 1)
    }

    @Test func aChangedClipBuildsAgain() throws {
        let (pane, host) = roundedPane()
        let before = try #require(host.cmuxClipPath()?.bounds)
        pane.layer?.cornerRadius = 4
        _ = host.cmuxClipPath()
        #expect(host.clipShapeBuilds == 2)
        host.frame = CGRect(x: 0, y: 0, width: 200, height: 300)
        let after = try #require(host.cmuxClipPath()?.bounds)
        #expect(host.clipShapeBuilds == 3)
        #expect(after.width < before.width, "the clip follows the new bounds")
    }

    /// A pane that moves keeps its host's local clip: the move costs no build.
    @Test func aMovedPaneReusesTheClip() {
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 1_000, height: 800))
        let (pane, host) = roundedPane()
        root.addSubview(pane)
        _ = host.cmuxClipPath()
        for step in 1...10 { pane.frame.origin.x = CGFloat(step * 7) }
        _ = host.cmuxClipPath()
        #expect(host.clipShapeBuilds == 1)
    }

    /// A hidden host shows no page; the fork hides its page through the probe
    /// when the view hides, so a window-wide page update skips it.
    @Test func aHiddenHostAsksForNoUpdate() {
        let (_, host) = roundedPane()
        var posts = 0
        let token = NotificationCenter.default.addObserver(forName: CEFHostView.geometryDidChange, object: host, queue: nil) { _ in
            posts += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }
        host.isHidden = true
        host.postGeometryChange()
        host.occlusionRects = [CGRect(x: 0, y: 0, width: 10, height: 10)]
        #expect(posts == 0)
    }
}
