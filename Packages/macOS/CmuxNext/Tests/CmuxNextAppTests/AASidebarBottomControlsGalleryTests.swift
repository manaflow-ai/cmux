import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// Stills of the sidebar's bottom-left corner in every `sidebar.bottomControls` look (Leo 2026-11-05: "who
/// wants to click on circles that small these days"), light and dark, at each sidebar density, with an
/// 8x nearest-neighbor zoom of both bottom corners, plus `measurements.json`: the avatar's and Search's hit
/// frames and the + (New Workspace) button's column. `CMUX_TEST_REQUIRE_GUI=1`; writes
/// `sidebar-bottom-controls-gallery.tar` for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AASidebarBottomControlsGalleryTests {
    struct Shot {
        var image: CGImage
        var scale: CGFloat
        var measured: [String: [CGFloat]]
    }

    static func rect(_ r: NSRect) -> [CGFloat] { [r.minX, r.minY, r.width, r.height] }

    static func render(_ variant: SidebarBottomControlsVariant, density: SidebarDensity, dark: Bool) async throws -> Shot {
        _ = NSApplication.shared
        let previousMotion = Motion.reduceMotionOverride
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = previousMotion }
        TunableStore.shared.register(SidebarTunables.all)
        TunableStore.shared.activate(file: nil)
        let before = TunableStore.shared.override(SidebarTunables.bottomControls.key)
        TunableStore.shared.set(SidebarTunables.bottomControls.key, .choice(variant.rawValue))
        defer { TunableStore.shared.set(SidebarTunables.bottomControls.key, before) }
        let savedDensity = DesignSettings.shared.sidebarSections.density
        DesignSettings.shared.sidebarSections.density = density
        defer { DesignSettings.shared.sidebarSections.density = savedDensity }

        let width: CGFloat = 280, height: CGFloat = 300
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        let themeName = dark ? "Soft Blue" : "Soft Blue Light"
        let input = try AANestedGroupsGalleryTests.input(themeName)
        _ = ThemeScope.app.store.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(themeName), input: input, animated: false)
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor

        let model = SidebarModel(sections: AASidebarLookGalleryTests.sections())
        model.expanded = density == .expanded
        model.profileAvatar = SidebarAvatar(name: "Lawrence", color: .blue)
        model.profiles = (0..<3).map { SidebarProfile(id: ProfileKey("space\($0)"), name: "Space \($0)") }
        let design = DesignSettings()
        design.sidebarSections.density = density
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
        // Two passes: the look's added line moves the band, which the second pass reads.
        for _ in 0..<2 {
            sidebar.needsLayout = true
            sidebar.layoutSubtreeIfNeeded()
        }
        sidebar.setChromeRevealed(true)
        sidebar.layoutSubtreeIfNeeded()
        for view in AANestedGroupsGalleryTests.all(root) {
            view.layoutSubtreeIfNeeded()
            view.layer?.removeAllAnimations()
            view.needsDisplay = true
            view.displayIfNeeded()
        }
        CATransaction.flush()

        var measured: [String: [CGFloat]] = [:]
        measured["newButton"] = rect(sidebar.newButton.frame)
        if !sidebar.searchButton.isHidden { measured["searchButton"] = rect(sidebar.searchButton.frame) }
        if let control = sidebar.footerBand.profileControl {
            let frame = sidebar.convert(control.view.bounds, from: control.view)
            measured["avatarTile"] = rect(frame)
            measured["avatarCircle"] = rect(sidebar.convert(control.view.avatarView.circleFrame, from: control.view.avatarView))
        }
        for (name, view) in [("largeAvatar", sidebar.bottomControls.avatarButton as NSView),
                             ("searchField", sidebar.bottomControls.searchField), ("accountRow", sidebar.bottomControls.accountRow)]
            where !view.isHidden {
            measured[name] = rect(view.frame)
        }
        if !sidebar.bottomControls.avatarButton.isHidden {
            let button = sidebar.bottomControls.avatarButton
            measured["largeAvatarCircle"] = rect(sidebar.convert(button.circleFrame, from: button))
        }
        measured["spaces"] = rect(sidebar.convert(sidebar.profileBar.bounds, from: sidebar.profileBar))
        measured["footer"] = rect(sidebar.footer.frame)
        measured["trailingColumnCenterX"] = [SidebarStyle.trailingColumnCenterX(sidebarWidth: width)]
        measured["sidebarRowHeight"] = [Metrics.sidebarRowHeight]

        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let image = try #require(rep.cgImage)
        window.close()
        return Shot(image: image, scale: CGFloat(image.width) / width, measured: measured)
    }

    /// `region` (points, top-left origin) of `image`, drawn `zoom` times larger with no smoothing.
    static func zoomed(_ image: CGImage, scale: CGFloat, region: CGRect, zoom: Int) throws -> CGImage {
        let px = CGRect(x: region.minX * scale, y: region.minY * scale, width: region.width * scale, height: region.height * scale).integral
        let crop = try #require(image.cropping(to: px))
        let ctx = try #require(CGContext(data: nil, width: crop.width * zoom, height: crop.height * zoom, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.interpolationQuality = .none
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        return try #require(ctx.makeImage())
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() async throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "sidebar-bottom-controls-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var measurements: [String: [String: [CGFloat]]] = [:]
        for density in [SidebarDensity.comfortable, .expanded, .compact] {
            // Compact keeps the shipped footer whatever the look: one still proves it.
            let variants: [SidebarBottomControlsVariant] = density == .compact ? [.standard, .largeTargets] : SidebarBottomControlsVariant.allCases
            for variant in variants {
                for dark in [false, true] {
                    let shot = try await Self.render(variant, density: density, dark: dark)
                    let name = "\(density.rawValue)-\(variant.rawValue)-\(dark ? "dark" : "light")"
                    measurements[name] = shot.measured
                    try AAGroupHeaderDensityGalleryTests.write(shot.image, to: out.appending(path: "\(name).png"))
                    let h = CGFloat(shot.image.height) / shot.scale
                    let w = CGFloat(shot.image.width) / shot.scale
                    // CGImage rows run top-down: the corner is the bottom 56 pt.
                    try AAGroupHeaderDensityGalleryTests.write(
                        try Self.zoomed(shot.image, scale: shot.scale, region: CGRect(x: 0, y: h - 56, width: 96, height: 56), zoom: 8),
                        to: out.appending(path: "\(name)-corner-left-8x.png"))
                    try AAGroupHeaderDensityGalleryTests.write(
                        try Self.zoomed(shot.image, scale: shot.scale, region: CGRect(x: w - 64, y: h - 56, width: 64, height: 56), zoom: 8),
                        to: out.appending(path: "\(name)-corner-right-8x.png"))
                    try AAGroupHeaderDensityGalleryTests.write(
                        try Self.zoomed(shot.image, scale: shot.scale, region: CGRect(x: w - 64, y: 0, width: 64, height: 44), zoom: 8),
                        to: out.appending(path: "\(name)-top-right-8x.png"))
                }
            }
        }
        let json = try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: out.appending(path: "measurements.json"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "sidebar-bottom-controls-gallery.tar", "sidebar-bottom-controls-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
