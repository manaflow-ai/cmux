import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// The left bar (`GroupLineView`, the group rail) up close, for Lawrence msg 19775 ("roundness of left bar needs to
/// be better, like rounded on both top and bottom"): the real sidebar list drawn offscreen at each density, in the
/// shipped line look and the connected (Chrome-Style Groups) look, light and dark (Soft Blue). Each crop holds the
/// open group's header bottom, its whole rail and the row under it, scaled up 4x; `left-bar.png` puts them on one
/// sheet (rows: densities; columns: line light, line dark, connected light, connected dark). Written under
/// `left-bar-gallery/` in the package and bundled to `left-bar-gallery.tar` for `cmux-ci run --artifact`. Runs only
/// with `CMUX_TEST_REQUIRE_GUI=1`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AALeftBarGalleryTests {
    static let zoom = 4

    /// The sidebar list in `theme`, and the crop around the open group's rail, in the image's pixels (top-down rows).
    static func render(theme: String, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let width: CGFloat = 260, height: CGFloat = 420
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        let input = try AANestedGroupsGalleryTests.input(theme)
        _ = ThemeScope.app.store.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(theme), input: input, animated: false)
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor
        let list = SidebarListView(model: SidebarModel(sections: AAGroupLineGalleryTests.sections(), activeWorkspaceID: WorkspaceID("nightly")))
        list.frame = NSRect(x: 0, y: 0, width: width, height: height)
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        list.frame.origin.y = height - list.frame.height
        root.layoutSubtreeIfNeeded()
        for view in AANestedGroupsGalleryTests.all(root) { view.needsDisplay = true; view.displayIfNeeded() }
        CATransaction.flush()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let image = try #require(rep.cgImage)
        // The "Nightly & CI" group: a top-level open group with a selected member, the screenshot's case.
        let rail = try #require(list.groupLineViews.shown[GroupID("g-ci")]?.frame, "the open group draws no rail")
        let inRoot = root.convert(rail, from: list)
        let s = CGFloat(image.width) / width
        let box = CGRect(x: 0, y: (height - inRoot.maxY - 14) * s, width: 56 * s, height: (inRoot.height + 28) * s).integral
        return try #require(image.cropping(to: box.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))))
    }

    /// `image` scaled up by `zoom` with no smoothing, so single pixels of the caps stay visible.
    static func zoomed(_ image: CGImage) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: image.width * zoom, height: image.height * zoom, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width * zoom, height: image.height * zoom))
        return try #require(context.makeImage())
    }

    static func write(_ image: CGImage, to url: URL) throws {
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let out = AANestedGroupsGalleryTests.packageRoot.appending(path: "left-bar-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let looks: [(name: String, connected: Bool, theme: String, dark: Bool)] = [
            ("line-light", false, "Soft Blue Light", false), ("line-dark", false, "Soft Blue", true),
            ("connected-light", true, "Soft Blue Light", false), ("connected-dark", true, "Soft Blue", true),
        ]
        var sheet: [[CGImage]] = []
        for density in SidebarDensity.allCases {
            var row: [CGImage] = []
            try SidebarGroupRailAlignmentTests.with(density, .off) {
                for look in looks {
                    try SidebarGroupChromeShapeTests.withShape(look.connected) {
                        let crop = try Self.zoomed(Self.render(theme: look.theme, dark: look.dark))
                        try Self.write(crop, to: out.appending(path: "\(density.rawValue)-\(look.name).png"))
                        row.append(crop)
                    }
                }
            }
            sheet.append(row)
        }
        // One sheet: a 16 px gutter between crops, on a mid grey so both light and dark crops read.
        let gap = 16
        let cellW = sheet.flatMap { $0 }.map(\.width).max() ?? 0, cellH = sheet.flatMap { $0 }.map(\.height).max() ?? 0
        let columns = looks.count, rows = sheet.count
        let context = try #require(CGContext(data: nil, width: columns * cellW + (columns + 1) * gap, height: rows * cellH + (rows + 1) * gap,
                                             bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        for (r, images) in sheet.enumerated() {
            for (col, image) in images.enumerated() {
                let y = context.height - (r + 1) * (cellH + gap) // row 0 at the top
                context.draw(image, in: CGRect(x: gap + col * (cellW + gap), y: y, width: image.width, height: image.height))
            }
        }
        try Self.write(try #require(context.makeImage()), to: out.appending(path: "left-bar.png"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = AANestedGroupsGalleryTests.packageRoot
        tar.arguments = ["cf", "left-bar-gallery.tar", "left-bar-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
