import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxTheme
import Foundation
import Testing

/// Stills for Leo 2026-11-07 ("it's super weird how when you drag ANY workspace, it shifts imediately due to that"),
/// dark and light, on the `SidebarDragStartKeepsRowsTests` sidebar (an empty Pinned over five rows), on the list and
/// on the document:
/// - `rest-*`: before the press;
/// - `lift-*`: `c` lifted and held 6 pt down;
/// - `top-*`: the held drag moved up to the top of the list.
/// Written under `drag-start-gallery/` and bundled to `drag-start-gallery.tar` for `cmux-ci run --artifact`, so a run
/// before the fix and one after compare.
@MainActor @Suite(.serialized) struct AADragStartGalleryTests {
    typealias Rows = SidebarDragStartKeepsRowsTests

    static func shot(_ window: NSWindow) throws -> CGImage {
        let root = try #require(window.contentView)
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

    static func theme(_ window: NSWindow, dark: Bool) throws {
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = try #require(window.contentView)
        root.wantsLayer = true
        root.appearance = window.appearance
        let theme = dark ? "Soft Blue" : "Soft Blue Light"
        let input = try AANestedGroupsGalleryTests.input(theme)
        _ = ThemeScope.app.store.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(theme), input: input, animated: false)
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let out = AANestedGroupsGalleryTests.packageRoot.appending(path: "drag-start-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for dark in [true, false] {
            for document in [false, true] {
                let name = "\(document ? "document" : "list")-\(dark ? "dark" : "light")"
                let (list, window) = Rows.list(document: document)
                defer { window.close() }
                try Self.theme(window, dark: dark)
                list.reload(animated: false)
                try AAGroupHeaderDensityGalleryTests.write(Self.shot(window), to: out.appending(path: "rest-\(name).png"))
                let (_, start) = try Rows.lift(list)
                list.updateDrag(windowPoint: list.convert(NSPoint(x: start.x, y: start.y + 6), to: nil))
                try AAGroupHeaderDensityGalleryTests.write(Self.shot(window), to: out.appending(path: "lift-\(name).png"))
                var y = start.y + 6
                while y > 8 {
                    y = max(8, y - 6)
                    list.updateDrag(windowPoint: list.convert(NSPoint(x: start.x, y: y), to: nil))
                }
                try AAGroupHeaderDensityGalleryTests.write(Self.shot(window), to: out.appending(path: "top-\(name).png"))
                list.cancelDrag()
            }
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = AANestedGroupsGalleryTests.packageRoot
        tar.arguments = ["cf", "drag-start-gallery.tar", "drag-start-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
