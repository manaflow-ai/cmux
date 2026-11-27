import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxTheme
import Foundation
import Testing

/// Stills for Lawrence 2026-10-30 ("i tried to drag home around and now it's stuck in this state"), dark and light, on
/// the `SidebarHomePinnedDragHarness` sidebar (Home, three pinned rows, three workspace rows):
/// - `home-drag-held-*`: a press on Home dragged 60 pt down, before the release;
/// - `home-drag-released-*`: after that drag went back and was released on Home;
/// - `pinned-interrupted-*`: a press on the first pinned row, then the app deactivated (no release came).
/// Written under `home-drag-gallery/` and bundled to `home-drag-gallery.tar` for `cmux-ci run --artifact`, so a run
/// before the fix and one after compare.
@MainActor @Suite(.serialized) struct AAHomeDragGalleryTests {
    typealias Harness = SidebarHomePinnedDragHarness

    static func shot(_ h: Harness, dark: Bool) throws -> CGImage {
        let root = try #require(h.window.contentView)
        for view in AANestedGroupsGalleryTests.all(root) {
            view.layoutSubtreeIfNeeded()
            view.layer?.removeAllAnimations()
            view.needsDisplay = true
            view.displayIfNeeded()
        }
        CATransaction.flush()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        return try #require(rep.cgImage)
    }

    static func themed(dark: Bool) throws -> Harness {
        let h = Harness()
        h.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = try #require(h.window.contentView)
        root.wantsLayer = true
        root.appearance = h.window.appearance
        let theme = dark ? "Soft Blue" : "Soft Blue Light"
        let input = try AANestedGroupsGalleryTests.input(theme)
        _ = ThemeScope.app.store.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(theme), input: input, animated: false)
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor
        h.settle()
        return h
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let out = AANestedGroupsGalleryTests.packageRoot.appending(path: "home-drag-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for dark in [true, false] {
            let look = dark ? "dark" : "light"
            do {
                let h = try Self.themed(dark: dark)
                defer { h.close() }
                let home = try h.item(Harness.home.id)
                let start = home.convert(NSPoint(x: home.bounds.midX, y: home.bounds.midY), to: nil)
                home.mouseDown(with: try h.mouse(.leftMouseDown, at: start))
                for down: CGFloat in [6, 30, 60] {
                    home.mouseDragged(with: try h.mouse(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - down)))
                }
                try AAGroupHeaderDensityGalleryTests.write(Self.shot(h, dark: dark), to: out.appending(path: "home-drag-held-\(look).png"))
                for down: CGFloat in [30, 4] {
                    home.mouseDragged(with: try h.mouse(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - down)))
                }
                home.mouseUp(with: try h.mouse(.leftMouseUp, at: NSPoint(x: start.x, y: start.y - 4)))
                h.finishFlights()
                try AAGroupHeaderDensityGalleryTests.write(Self.shot(h, dark: dark), to: out.appending(path: "home-drag-released-\(look).png"))
            }
            do {
                let h = try Self.themed(dark: dark)
                defer { h.close() }
                let pin = try h.item(Harness.pins[0].id)
                pin.mouseDown(with: try h.event(.leftMouseDown, on: pin))
                h.list.pointerFocusLost()
                h.finishFlights()
                try AAGroupHeaderDensityGalleryTests.write(Self.shot(h, dark: dark), to: out.appending(path: "pinned-interrupted-\(look).png"))
            }
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = AANestedGroupsGalleryTests.packageRoot
        tar.arguments = ["cf", "home-drag-gallery.tar", "home-drag-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
