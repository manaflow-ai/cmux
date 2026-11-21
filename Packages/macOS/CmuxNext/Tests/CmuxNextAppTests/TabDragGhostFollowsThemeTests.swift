import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// Lawrence 2026-11-08: a tab brought back into its bar showed a light ghost in dark mode. The ghost's tab image
/// was a bitmap drawn once at pickup, in the theme of that moment; a light/dark switch while the drag was held
/// (the capture runner's, Auto appearance at dusk, a theme pick) left the ghost in the old colors while the bar
/// under it changed. The ghost must follow the app's theme: switched mid-drag, it is drawn again in the new one.
/// Real window, strip and drag session; the theme switch goes through the app's theme store, as a config reload
/// or an appearance flip does. Opaque and translucent windows both.
@MainActor @Suite(.serialized, .closesItsWindows,
                 .enabled(if: !NSScreen.screens.isEmpty || ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1",
                          "the drag tests need a display"))
struct TabDragGhostFollowsThemeTests {
    static let light = ThemeRGB(r: 0xFA, g: 0xFA, b: 0xFA)
    static let dark = ThemeRGB(r: 0x1E, g: 0x1E, b: 0x1E)

    @Test(arguments: [1.0, 0.65])
    func aThemeSwitchMidDragRedrawsTheGhost(opacity: Double) async throws {
        let original = ThemeScope.app.store.input
        defer { _ = ThemeScope.app.store.apply(original) }
        _ = ThemeScope.app.store.apply(ThemeInput(background: Self.light, foreground: Self.dark, backgroundOpacity: opacity, backgroundBlur: 20))

        let f = try await TabDragFollowsPointerTests.fixture(tabCount: 3)
        defer { f.close() }
        let source = try #require(f.controller.content?.panes.values.first)
        let strip = source.view.stripView
        let cell = try #require(strip.cells[CmuxNextTabs.TabID(source.pane.tabs[1].id)])
        let frame = strip.tabsClip.convert(cell.frame, to: nil)
        let start = NSPoint(x: frame.midX, y: frame.midY)
        strip.mouseDown(with: try f.event(.leftMouseDown, at: start))
        let session = f.services.dragSession
        // Down out of the bar: the session takes the tab over and its ghost shows the tab.
        for step in 1...10 {
            let event = try f.event(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - 12 * CGFloat(step)))
            if session.drag != nil { _ = session.handle(event) } else { strip.mouseDragged(with: event) }
            f.frame()
        }
        let drag = try #require(session.drag, "the tab never left its bar")
        let before = try #require(Self.fillLuminance(Self.tabImage(of: drag.ghost)), "the ghost shows no tab image")
        #expect(before > 0.6, "in the light theme the ghost's tab is not light: luminance \(before)")

        _ = ThemeScope.app.store.apply(ThemeInput(background: Self.dark, foreground: Self.light, backgroundOpacity: opacity, backgroundBlur: 20))
        for _ in 0..<6 { f.frame() }
        let after = try #require(Self.fillLuminance(Self.tabImage(of: drag.ghost)), "the ghost lost its tab image")
        #expect(after < 0.4, "switched to the dark theme mid-drag, the ghost keeps its light tab: luminance \(before) -> \(after)")
        session.finish(commit: false)
        session.finishLanding()
        f.frame()
    }

    /// The redrawn image is the tab as the strip draws it, the right way up: a lone cell has no flipped
    /// ancestor, and drawn without one its title and icon came out upside down (">_" as ">‾").
    @Test
    func theRedrawnImageMatchesTheStripsOwnDrawing() async throws {
        let original = ThemeScope.app.store.input
        defer { _ = ThemeScope.app.store.apply(original) }
        _ = ThemeScope.app.store.apply(ThemeInput(background: Self.dark, foreground: Self.light, backgroundOpacity: 1, backgroundBlur: 0))
        let f = try await TabDragFollowsPointerTests.fixture(tabCount: 3)
        defer { f.close() }
        let source = try #require(f.controller.content?.panes.values.first)
        let strip = source.view.stripView
        let id = CmuxNextTabs.TabID(source.pane.tabs[1].id)
        let cell = try #require(strip.cells[id])
        cell.isWindowMain = true
        cell.isLifted = true
        cell.setFrame(cell.frame, laysOut: true)
        f.frame()
        let live = try #require(strip.snapshot(of: [cell.layer], frame: cell.frame).image?.cgImage)
        let redrawn = try #require(strip.dragImage(of: id, size: cell.frame.size)?.image?.cgImage)
        let differing = try #require(Self.differingFraction(live, redrawn))
        #expect(differing < 0.004, "the redrawn ghost tab differs from the strip's own drawing in \(differing * 100)% of its pixels")
    }

    /// The fraction of pixels whose channels differ by more than a quarter between two same-size images.
    static func differingFraction(_ a: CGImage, _ b: CGImage) -> Double? {
        guard a.width == b.width, a.height == b.height, let pa = rgba(a), let pb = rgba(b) else { return nil }
        var differing = 0
        for i in stride(from: 0, to: pa.count, by: 4) where (0..<4).contains(where: { abs(Int(pa[i + $0]) - Int(pb[i + $0])) > 64 }) {
            differing += 1
        }
        return Double(differing) / Double(pa.count / 4)
    }

    static func rgba(_ image: CGImage) -> [UInt8]? {
        let (w, h) = (image.width, image.height)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? pixels : nil
    }

    /// The tab image the ghost draws: its layer that stretches its contents to the tab (the thumbnail fills).
    static func tabImage(of ghost: TabDragGhostPanel) -> CGImage? {
        func walk(_ layer: CALayer) -> CGImage? {
            if layer.contentsGravity == .resize, let contents = layer.contents as CFTypeRef?, CFGetTypeID(contents) == CGImage.typeID {
                return unsafeDowncast(contents, to: CGImage.self)
            }
            for sub in layer.sublayers ?? [] { if let image = walk(sub) { return image } }
            return nil
        }
        return ghost.panel.contentView?.layer.flatMap(walk)
    }

    /// Mean luminance (0...1) of the image's mostly opaque pixels, unpremultiplied: the tab's fill, whatever
    /// glass would show through the rest.
    static func fillLuminance(_ image: CGImage?) -> Double? {
        guard let image else { return nil }
        let (w, h) = (image.width, image.height)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var sum = 0.0
        var count = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[i + 3]) / 255
            guard a > 0.3 else { continue }
            let r = Double(pixels[i]) / 255 / a, g = Double(pixels[i + 1]) / 255 / a, b = Double(pixels[i + 2]) / 255 / a
            sum += 0.2126 * r + 0.7152 * g + 0.0722 * b
            count += 1
        }
        return count > 0 ? sum / Double(count) : nil
    }
}
