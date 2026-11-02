import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxTheme
import Foundation
import Testing

/// Four native-sidebar comparisons for Leo's 2026-11-01 dot/+ visibility choice.
/// The artifact includes light/dark rest/hover captures and a contact-sheet HTML page.
@MainActor @Suite(.serialized) struct ProfileBarVariantGalleryTests {
    private static func render(_ h: SidebarTrailingColumnTests.KindHarness) throws -> CGImage {
        let root = try #require(h.window.contentView)
        for view in AANestedGroupsGalleryTests.all(root) { view.layoutSubtreeIfNeeded(); view.needsDisplay = true; view.displayIfNeeded() }
        CATransaction.flush()
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: Int(root.bounds.width * 2), height: Int(root.bounds.height * 2),
                                            bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: 2, y: 2)
        try #require(root.layer).render(in: context)
        return try #require(context.makeImage())
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderDotAndPlusChoices() throws {
        let design = DesignSettings.shared
        let saved = (design.sidebarSections.showSpaces, design.sidebarSections.showSearchButton, design.sidebarSections.noFade)
        defer {
            design.sidebarSections.showSpaces = saved.0
            design.sidebarSections.showSearchButton = saved.1
            design.sidebarSections.noFade = saved.2
        }
        design.sidebarSections.showSpaces = true
        design.sidebarSections.showSearchButton = true
        design.sidebarSections.noFade = false
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "sidebar-space-variants")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let variants: [(String, Bool, Bool)] = [
            ("dot-always-plus-hover", true, false), ("dot-hover-plus-hover", false, false),
            ("dot-always-plus-always", true, true), ("dot-hover-plus-always", false, true),
        ]
        var html = "<meta charset='utf-8'><title>Sidebar space controls</title><style>body{font:16px system-ui;background:#ddd}section{display:inline-block;vertical-align:top;margin:12px}img{width:300px}</style>"
        html += "<h1>Sidebar space controls</h1><p>Chosen: dot always, + on hover. The resting dot locates the space; + replaces it without moving. Always + consumes the only slot, while hover-only dots leave no resting landmark.</p>"
        for (theme, appearance) in [("Apple System Colors Light", NSAppearance.Name.aqua), ("Apple System Colors", .darkAqua)] {
            let h = SidebarTrailingColumnTests.KindHarness(width: 300)
            defer { h.window.close() }
            h.window.setContentSize(NSSize(width: 300, height: 500))
            h.sidebar.frame = NSRect(x: 0, y: 0, width: 300, height: 500)
            h.sidebar.spacesPosition = .bottom
            h.model.profiles = [SidebarProfile(id: ProfileKey("gallery-space"), name: "Personal")]
            h.model.activeProfileID = h.model.profiles[0].id
            h.sidebar.renderNow()
            h.sidebar.layoutSubtreeIfNeeded()
            #expect(!h.sidebar.profileBar.isHidden, "one space must remain mounted in the real sidebar")
            h.window.appearance = NSAppearance(named: appearance)
            let input = try AANestedGroupsGalleryTests.input(theme)
            _ = ThemeScope.app.store.apply(input)
            let scope = ThemeScope(level: .room)
            scope.setOverride(ThemeSpec(theme), input: input, animated: false)
            let content = try #require(h.window.contentView)
            content.wantsLayer = true
            scope.root(content)
            content.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor
            let bar = h.sidebar.profileBar
            let mode = appearance == .aqua ? "light" : "dark"
            for (name, dots, plus) in variants {
                bar.showsDotsWhenIdle = dots
                bar.showsPlusWhenIdle = plus
                html += "<section><h2>\(mode): \(name)</h2>"
                for hovered in [false, true] {
                    bar.setPointerInside(hovered)
                    bar.setHovered(hovered ? ProfileBarView.plusIndex : nil)
                    bar.refresh()
                    let row = try #require(h.list.rowViews[.workspace(SidebarTrailingColumnTests.member)] as? WorkspaceRowView)
                    row.onMore = {}
                    row.isHovered = hovered
                    let state = hovered ? "hover" : "rest"
                    let file = "\(mode)-\(name)-\(state).png"
                    let image = try Self.render(h)
                    try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: file))
                    html += "<figure><img src='\(file)' alt='\(name) \(state)'><figcaption>\(state)</figcaption></figure>"
                }
                html += "</section>"
            }
        }
        try html.write(to: out.appending(path: "index.html"), atomically: true, encoding: .utf8)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "sidebar-space-variants.tar", "sidebar-space-variants"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
