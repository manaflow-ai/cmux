import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxTheme
import Foundation
import Testing

/// Before/after stills of the sidebar's footer and hover chrome (Lawrence 2026-10-27 message 14242:
/// the Search button on the right; the controls show only on hover). The whole
/// sidebar, dark, two spaces and a profile avatar, the pointer away and over it, with
/// `sidebar.controlsOnHover` off and on. `CMUX_TEST_REQUIRE_GUI=1`; writes
/// `sidebar-footer-gallery.tar` for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized) struct AASidebarFooterGalleryTests {
    static func render(minimal: Bool, hovered: Bool) async throws -> CGImage {
        _ = NSApplication.shared
        let previousMotion = Motion.reduceMotionOverride
        Motion.reduceMotionOverride = true // the reveal snaps: no fade caught halfway
        defer { Motion.reduceMotionOverride = previousMotion }
        let width: CGFloat = 280, height: CGFloat = 260
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        let input = try AANestedGroupsGalleryTests.input("Soft Blue")
        _ = ThemeScope.app.store.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec("Soft Blue"), input: input, animated: false)
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor

        let model = SidebarModel(sections: AASidebarLookGalleryTests.sections())
        model.profileAvatar = SidebarAvatar(name: "Lawrence", color: .blue)
        model.profiles = (0..<2).map { SidebarProfile(id: ProfileKey("space\($0)"), name: "Space \($0)") }
        let design = DesignSettings()
        design.sidebarSections.controlsOnHover = minimal // after-only
        let sidebar = SidebarView(model: model, design: design)
        sidebar.frame = root.bounds
        root.addSubview(sidebar)
        window.orderFrontRegardless()
        for _ in 0..<20 {
            sidebar.renderNow()
            sidebar.needsLayout = true
            sidebar.layoutSubtreeIfNeeded()
            if sidebar.footerBand.profileControl != nil { break }
            await Task.yield()
        }
        sidebar.setChromeRevealed(!hovered)
        sidebar.setChromeRevealed(hovered)
        sidebar.layoutSubtreeIfNeeded()
        for view in AANestedGroupsGalleryTests.all(root) {
            view.layoutSubtreeIfNeeded()
            view.layer?.removeAllAnimations()
            view.needsDisplay = true
            view.displayIfNeeded()
        }
        CATransaction.flush()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let image = try #require(rep.cgImage)
        window.close()
        return image
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() async throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "sidebar-footer-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var variants: [(name: String, minimal: Bool)] = [("default", false)]
        variants.append(("minimal", true)) // after-only
        var images: [CGImage] = []
        for variant in variants {
            for hovered in [false, true] {
                let image = try await Self.render(minimal: variant.minimal, hovered: hovered)
                images.append(image)
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(variant.name)-\(hovered ? "hover" : "rest").png"))
            }
        }
        let w = images[0].width, h = images[0].height, gap = 16
        let ctx = try #require(CGContext(data: nil, width: images.count * w + (images.count - 1) * gap, height: h, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (i, image) in images.enumerated() {
            ctx.draw(image, in: CGRect(x: i * (w + gap), y: 0, width: w, height: h))
        }
        try AAGroupHeaderDensityGalleryTests.write(try #require(ctx.makeImage()), to: out.appending(path: "all.png"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "sidebar-footer-gallery.tar", "sidebar-footer-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
