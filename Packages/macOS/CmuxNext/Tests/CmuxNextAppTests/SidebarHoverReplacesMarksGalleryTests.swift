import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// Leo 2026-11-22: "in all cases, the hovered buttons should just replace the other ones." One row per mark set (the
/// blue dot, an unread count, the error mark, everything at once), drawn at rest and hovered, dark and light: the
/// hovered cells show only the controls in the trailing cluster. Artifact `sidebar-hover-replaces-gallery.tar`
/// (`CMUX_TEST_REQUIRE_GUI=1`).
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarHoverReplacesMarksGalleryTests {
    static let variants: [SidebarRowCloseClearsMarksTests.Marks] = [.unreadDot, .unreadCount, .error, .pullRequestCount, .everything]

    static func render(_ marks: SidebarRowCloseClearsMarksTests.Marks, hovered: Bool, dark: Bool) throws -> CGImage {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let (sidebar, window) = SidebarRowCloseClearsMarksTests.sidebar(marks, style: .corner)
        defer { window.close() }
        sidebar.list.model.workspacePin = (isPinned: { _ in false }, toggle: { _ in })
        sidebar.list.contextMenuProvider = { _ in NSMenu() }
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
        sidebar.renderNow()
        let row = try #require(sidebar.list.rowViews[.workspace(SidebarRowCloseClearsMarksTests.row)] as? WorkspaceRowView)
        row.wire(SidebarRowCloseClearsMarksTests.row, in: sidebar.list)
        row.isHovered = hovered
        for view in AANestedGroupsGalleryTests.all(root) { view.layoutSubtreeIfNeeded(); view.needsDisplay = true; view.displayIfNeeded() }
        CATransaction.flush()
        // The hovered row alone, so a column reads rest | hovered per mark set.
        let frame = row.convert(row.bounds, to: root)
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: frame))
        root.cacheDisplay(in: frame, to: rep)
        return try #require(rep.cgImage)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderEveryMarkSetAtRestAndHovered() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "sidebar-hover-replaces-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // Rows: each mark set; columns: dark rest, dark hovered, light rest, light hovered.
        var grid: [[CGImage]] = []
        for marks in Self.variants {
            var line: [CGImage] = []
            for dark in [true, false] {
                for hovered in [false, true] {
                    let image = try Self.render(marks, hovered: hovered, dark: dark)
                    let name = "\(marks.rawValue)-\(dark ? "dark" : "light")-\(hovered ? "hover" : "rest").png"
                    try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: name))
                    line.append(image)
                }
            }
            grid.append(line)
        }
        let gap = 8, cell = try #require(grid.first?.first)
        let columns = grid[0].count
        let width = (cell.width + gap) * columns, height = (cell.height + gap) * grid.count
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (r, line) in grid.enumerated() {
            for (c, image) in line.enumerated() {
                ctx.draw(image, in: CGRect(x: c * (cell.width + gap), y: height - (r + 1) * (cell.height + gap), width: image.width, height: image.height))
            }
        }
        try AAGroupHeaderDensityGalleryTests.write(try #require(ctx.makeImage()), to: out.appending(path: "all.png"))
        let tar = Process(); tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar"); tar.currentDirectoryURL = root
        tar.arguments = ["cf", "sidebar-hover-replaces-gallery.tar", "sidebar-hover-replaces-gallery"]
        try tar.run(); tar.waitUntilExit(); #expect(tar.terminationStatus == 0)
    }
}
