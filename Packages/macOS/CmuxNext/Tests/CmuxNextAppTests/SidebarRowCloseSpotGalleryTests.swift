import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// Every `sidebar.rowCloseSpot` choice on a hovered working row, dark and light, one sidebar per
/// column (Leo 2026-10-27: "the rightmost three things, they make sense, but this one, not so much"). Artifact
/// `sidebar-close-spot-gallery.tar` (`CMUX_TEST_REQUIRE_GUI=1`).
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarRowCloseSpotGalleryTests {
    static func render(_ spot: SidebarRowCloseSpot, dark: Bool) throws -> CGImage {
        try SidebarRowCloseSpotTests.withCloseSpot(spot) {
            let (_, sidebar, window) = SidebarRowCloseSpotTests.sidebar()
            defer { window.close() }
            // As the nested-groups gallery: each mode its own theme, the appearance on the view, an opaque backdrop.
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
            let row = try #require(sidebar.list.rowViews[.workspace(SidebarRowCloseSpotTests.other)] as? WorkspaceRowView)
            row.isHovered = true
            for view in AANestedGroupsGalleryTests.all(root) { view.layoutSubtreeIfNeeded(); view.needsDisplay = true; view.displayIfNeeded() }
            CATransaction.flush()
            let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: rep)
            return try #require(rep.cgImage)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderEveryCloseSpot() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "sidebar-close-spot-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var images: [[CGImage]] = []
        for dark in [true, false] {
            var line: [CGImage] = []
            for spot in SidebarRowCloseSpot.allCases {
                let image = try Self.render(spot, dark: dark)
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(spot.rawValue)-\(dark ? "dark" : "light").png"))
                line.append(image)
            }
            images.append(line)
        }
        let gap = 16, cell = try #require(images.first?.first)
        let width = (cell.width + gap) * SidebarRowCloseSpot.allCases.count, height = (cell.height + gap) * images.count
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
        tar.arguments = ["cf", "sidebar-close-spot-gallery.tar", "sidebar-close-spot-gallery"]
        try tar.run(); tar.waitUntilExit(); #expect(tar.terminationStatus == 0)
    }
}
