import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxTheme
import Foundation
import Testing

/// The space switcher gallery (`sidebar.spaceSwitcher`, design/spaces.md "The switcher (PR 3)"): every style in the real
/// sidebar, light and dark, at rest and with the pointer on the space another window shows. Writes `spaces-switcher/`
/// (2x PNGs and an index page) and `spaces-switcher.tar` next to the package, as `ProfileBarVariantGalleryTests` does.
@MainActor @Suite(.serialized) struct SpaceSwitcherGalleryTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderSwitcherStyles() throws {
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
        let out = root.appending(path: "spaces-switcher")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var html = "<meta charset='utf-8'><title>Space switcher</title><style>body{font:16px system-ui;background:#ddd}section{display:inline-block;vertical-align:top;margin:12px}img{width:300px}</style>"
        html += "<h1>Space switcher: which window shows each space</h1><p>Chosen: ring. The dots strip stays as it is; a thin ring marks a space another window shows, a click offers Go to Window or Move Here, Option-click goes to the window.</p>"
        let spaces = [SidebarProfile(id: ProfileKey("work"), name: "Work", color: .blue), SidebarProfile(id: ProfileKey("home"), name: "Home", color: .green),
                      SidebarProfile(id: ProfileKey("research"), name: "Research", color: .orange), SidebarProfile(id: ProfileKey("errands"), name: "Errands")]
        for (theme, appearance) in [("Apple System Colors Light", NSAppearance.Name.aqua), ("Apple System Colors", .darkAqua)] {
            let h = SidebarTrailingColumnTests.KindHarness(width: 300)
            defer { h.window.close() }
            h.window.setContentSize(NSSize(width: 300, height: 500))
            h.sidebar.frame = NSRect(x: 0, y: 0, width: 300, height: 500)
            h.sidebar.spacesPosition = .bottom
            h.model.profiles = spaces
            h.model.activeProfileID = spaces[0].id
            h.model.spacesElsewhere = [spaces[1].id: SpaceElsewhere(windowID: "second", incognito: false),
                                       spaces[2].id: SpaceElsewhere(windowID: "third", incognito: false)]
            h.sidebar.renderNow()
            h.sidebar.layoutSubtreeIfNeeded()
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
            for style in SpaceSwitcherStyle.allCases {
                bar.switcherStyleOverride = style
                html += "<section><h2>\(mode): \(style.rawValue)</h2><p>\(style.tunableTitle)</p>"
                for hovered in [false, true] {
                    bar.setPointerInside(hovered)
                    bar.setHovered(hovered ? 1 : nil)
                    bar.refresh()
                    let state = hovered ? "hover" : "rest"
                    let file = "\(mode)-\(style.rawValue)-\(state).png"
                    try AAGroupHeaderDensityGalleryTests.write(try Self.render(h), to: out.appending(path: file))
                    html += "<figure><img src='\(file)' alt='\(style.rawValue) \(state)'><figcaption>\(state)</figcaption></figure>"
                }
                html += "</section>"
            }
        }
        try html.write(to: out.appending(path: "index.html"), atomically: true, encoding: .utf8)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "spaces-switcher.tar", "spaces-switcher"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }

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
}
