import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import Foundation
import Testing

/// The collapsed-sidebar title bar with its hover zone drawn over it, closed and opened, plus the measurements (Leo,
/// relaying Austin, 2026-10-28: "you only get that hoverable animation when you're in the area of the, like, the
/// rightmost area of the go forward button"). Red is the zone, green the open Forward button's trailing edge, grey dots
/// the traffic lights (the window draws those, not the root). Artifact `collapsed-titlebar-zone-gallery.tar`
/// (`CMUX_TEST_REQUIRE_GUI=1`).
@MainActor @Suite(.serialized) struct CollapsedTitlebarZoneGalleryTests {
    /// `CornerHoverBandTests.collapsedRoot` in a window with no screen, so the band's open snaps instead of animating
    /// (`Motion.canAnimate`).
    static func offscreenCollapsedRoot() -> (NSWindow, WindowRootView) {
        let (window, root) = CornerHoverBandTests().collapsedRoot()
        window.setFrameOrigin(NSPoint(x: -40_000, y: -40_000))
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        return (window, root)
    }

    /// The open band's Forward button in the root's coordinates, the band opened by the pointer.
    static func openForwardFrame(_ root: WindowRootView) throws -> CGRect {
        root.titlebarReveal.setPointerInside(true)
        root.layoutSubtreeIfNeeded()
        try #require(root.toolbarBand.presence == 1)
        let forward = root.toolbarBand.forwardButton
        return root.convert(forward.bounds, from: forward)
    }

    /// The root's top-left corner at `scale`, with the zone, the open Forward edge and the traffic lights drawn on it.
    static func render(_ root: WindowRootView, lights: CGRect, forwardMaxX: CGFloat, scale: CGFloat = 4) throws -> CGImage {
        for view in AANestedGroupsGalleryTests.all(root) { view.layoutSubtreeIfNeeded(); view.needsDisplay = true; view.displayIfNeeded() }
        CATransaction.flush()
        let zone = root.titlebarRevealRegion.frame
        let crop = CGRect(x: 0, y: zone.minY - 8, width: forwardMaxX + 48, height: zone.height + 8)
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: crop))
        root.cacheDisplay(in: crop, to: rep)
        let shot = try #require(rep.cgImage)
        let width = Int(crop.width * scale), height = Int(crop.height * scale)
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.draw(shot, in: CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -crop.minX, y: -crop.minY)
        ctx.setFillColor(CGColor(gray: 0.55, alpha: 1))
        for i in 0..<3 {
            let d = min(12, lights.height), step = lights.width / 3
            ctx.fillEllipse(in: CGRect(x: lights.minX + step * CGFloat(i) + (step - d) / 2, y: lights.midY - d / 2, width: d, height: d))
        }
        ctx.setFillColor(CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 0.28)); ctx.fill(zone)
        ctx.setStrokeColor(CGColor(red: 1, green: 0.25, blue: 0.25, alpha: 1)); ctx.setLineWidth(0.5); ctx.stroke(zone.insetBy(dx: 0.25, dy: 0.25))
        ctx.setStrokeColor(CGColor(red: 0.2, green: 0.9, blue: 0.3, alpha: 1))
        ctx.move(to: CGPoint(x: forwardMaxX, y: crop.minY)); ctx.addLine(to: CGPoint(x: forwardMaxX, y: crop.maxY)); ctx.strokePath()
        return try #require(ctx.makeImage())
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderTheCollapsedTitlebarZone() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "collapsed-titlebar-zone-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // Two windows: a closed band, and one opened by the pointer (a close waits out `closeDelay`).
        let (window, view) = Self.offscreenCollapsedRoot()
        let (openWindow, openView) = Self.offscreenCollapsedRoot()
        defer { window.close(); openWindow.close() }
        for each in [window, openWindow] { each.appearance = NSAppearance(named: .darkAqua) }
        let lights = view.convert(try #require(WindowTitlebar.trafficLightsFrame(in: window)), from: nil)
        let zone = view.titlebarRevealRegion.frame
        let closedBand = view.toolbarBand.frame
        let openForward = try Self.openForwardFrame(openView)
        let closed = try Self.render(view, lights: lights, forwardMaxX: openForward.maxX)
        try AAGroupHeaderDensityGalleryTests.write(closed, to: out.appending(path: "closed.png"))
        let open = try Self.render(openView, lights: lights, forwardMaxX: openForward.maxX)
        try AAGroupHeaderDensityGalleryTests.write(open, to: out.appending(path: "open.png"))
        let measured = """
            traffic lights maxX: \(lights.maxX)
            closed band frame: \(closedBand)
            open Forward frame: \(openForward)
            open Forward maxX: \(openForward.maxX)
            zone frame: \(zone)
            zone maxX: \(zone.maxX)
            zone maxX - Forward maxX: \(zone.maxX - openForward.maxX)
            """
        print("collapsed-titlebar-zone: \(measured)")
        try measured.write(to: out.appending(path: "measurements.txt"), atomically: true, encoding: .utf8)
        let tar = Process(); tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar"); tar.currentDirectoryURL = root
        tar.arguments = ["cf", "collapsed-titlebar-zone-gallery.tar", "collapsed-titlebar-zone-gallery"]
        try tar.run(); tar.waitUntilExit(); #expect(tar.terminationStatus == 0)
    }
}
