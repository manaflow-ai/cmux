import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxTheme
import Foundation
import Testing

/// A workspace's listed tabs with one tab row hovered, then the same sidebar after a middle-click on that row, dark
/// and light (Leo 2026-10-27: "we need to be able to middle-click and, you know, just deal with the stuff here. Like
/// just closing tabs fundamentally"). The sidebar stands alone, so the test drops a tab the sidebar asked to close, as
/// the store does once Close Tab ran; the intent is matched by name, so the same test runs on a build without it.
/// Artifact `sidebar-tab-middle-click-gallery.tar` (`CMUX_TEST_REQUIRE_GUI=1`).
@MainActor @Suite(.serialized) struct SidebarTabMiddleClickGalleryTests {
    typealias Fixture = SidebarTabGroupControlsTests

    /// The hovered row before the click, and the sidebar after it.
    static func render(dark: Bool) throws -> (hovered: CGImage, clicked: CGImage) {
        let (model, sidebar, window) = Fixture.sidebar()
        defer { window.close() }
        let theme = dark ? "Soft Blue" : "Soft Blue Light"
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = NSView(frame: sidebar.frame)
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        root.addSubview(sidebar)
        let input = try AANestedGroupsGalleryTests.input(theme)
        _ = ThemeScope.app.store.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(theme), input: input, animated: false)
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor
        window.orderFrontRegardless()
        // The store's part: a tab the sidebar asked to close leaves its workspace.
        // A listed tab leaving moves rows, so the sections are set (`patchWorkspaces` refuses that change).
        model.onIntent = { intent in
            guard String(describing: intent).hasPrefix("closeTab") else { return model.apply(intent) }
            model.sections = model.sections.map { section in
                var section = section
                section.nodes = section.nodes.map { node in
                    guard case var .workspace(row) = node, row.id == Fixture.shown else { return node }
                    row.tabs.removeAll { $0.id == Fixture.first }
                    return .workspace(row)
                }
                return section
            }
        }
        sidebar.renderNow()
        let list = sidebar.list
        let row = try Fixture.tabRow(list, Fixture.shown, Fixture.first)
        row.isHovered = true
        let hovered = try snapshot(root)
        try middleClick(list, .tab(Fixture.shown, Fixture.first))
        sidebar.renderNow()
        list.reload(animated: false)
        return (hovered, try snapshot(root))
    }

    /// A middle-button event (button number 2, as a real one) at `point` in `list`, through DebugMouse's mapping.
    static func middle(_ type: NSEvent.EventType, at point: NSPoint, in list: SidebarListView) throws -> NSEvent {
        let window = try #require(list.window)
        let base = list.convert(point, to: nil)
        let height = window.contentView?.bounds.height ?? window.frame.height
        let event = try #require(DebugMouse.mouse(type, at: NSPoint(x: base.x, y: height - base.y), in: window, flags: [], clicks: 1))
        #expect(event.buttonNumber == 2)
        return event
    }

    /// A middle press on `down`'s row and its release on `up`'s (the same row by default).
    static func middleClick(_ list: SidebarListView, _ down: SidebarRowKey, releasedOn up: SidebarRowKey? = nil) throws {
        let pressed = try SidebarIncrementalMatchesRebuildGapsTests.center(list, down)
        let released = try SidebarIncrementalMatchesRebuildGapsTests.center(list, up ?? down)
        list.otherMouseDown(with: try middle(.otherMouseDown, at: pressed, in: list))
        list.otherMouseUp(with: try middle(.otherMouseUp, at: released, in: list))
    }

    static func snapshot(_ root: NSView) throws -> CGImage {
        for view in AANestedGroupsGalleryTests.all(root) { view.layoutSubtreeIfNeeded(); view.needsDisplay = true; view.displayIfNeeded() }
        CATransaction.flush()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        return try #require(rep.cgImage)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderHoveredThenMiddleClicked() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "sidebar-tab-middle-click-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var images: [[CGImage]] = []
        for dark in [true, false] {
            let (hovered, clicked) = try Self.render(dark: dark)
            let mode = dark ? "dark" : "light"
            try AAGroupHeaderDensityGalleryTests.write(hovered, to: out.appending(path: "1-hovered-\(mode).png"))
            try AAGroupHeaderDensityGalleryTests.write(clicked, to: out.appending(path: "2-middle-clicked-\(mode).png"))
            images.append([hovered, clicked])
        }
        let gap = 16, cell = try #require(images.first?.first)
        let width = (cell.width + gap) * 2, height = (cell.height + gap) * images.count
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (r, line) in images.enumerated() {
            for (c, image) in line.enumerated() {
                ctx.draw(image, in: CGRect(x: c * (cell.width + gap), y: height - (r + 1) * (cell.height + gap), width: image.width, height: image.height))
            }
        }
        try AAGroupHeaderDensityGalleryTests.write(try #require(ctx.makeImage()), to: out.appending(path: "all.png"))
        let tar = Process(); tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar"); tar.currentDirectoryURL = root
        tar.arguments = ["cf", "sidebar-tab-middle-click-gallery.tar", "sidebar-tab-middle-click-gallery"]
        try tar.run(); tar.waitUntilExit(); #expect(tar.terminationStatus == 0)
    }
}
