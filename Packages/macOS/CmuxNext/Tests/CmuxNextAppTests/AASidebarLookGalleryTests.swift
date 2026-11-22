import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// Stills of the sidebar look the sidebar owner keeps (plans/cmux-next/sidebar-owner.md): Lawrence's
/// 2026-10-23 screenshots rebuilt as a fixture (a "cmux-next app" group with an emoji, loose rows, a
/// nested group), one member hovered so its close shows, at every `sidebar.density`, dark and light.
/// Written under `sidebar-look-gallery/` with `all.png` (dark on top, light below), bundled to
/// `sidebar-look-gallery.tar` for `cmux-ci run --artifact`, so a before and an after run compare.
@MainActor @Suite(.serialized, .closesItsWindows) struct AASidebarLookGalleryTests {
    static let hovered = SidebarRowKey.workspace(WorkspaceID("w-align"))

    static func sections() -> [SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        func ws(_ id: String, _ title: String, busy: Bool = false, tabs: [SidebarTab] = []) -> SidebarWorkspace {
            var workspace = SidebarWorkspace(id: WorkspaceID("w-\(id)"), title: title,
                                             activity: busy ? .busy(progress: nil) : .idle)
            workspace.tabs = tabs
            return workspace
        }
        var app = SidebarGroup(id: GroupID("g-app"), name: "cmux-next app", color: .blue, workspaces: [
            ws("reopen", "Reopen closes all", busy: true),
            ws("align", "Group bar left alignment", busy: true, tabs: [
                SidebarTab(id: TabID("align-shell"), title: "shell"),
                SidebarTab(id: TabID("align-browser"), title: "browser", isUnread: true),
            ]),
            ws("update", "Update stuck Installing", busy: true), ws("deep", "Group bar alignment, deep nesting"),
        ])
        app.icon = .emoji("😇")
        var perf = SidebarGroup(id: GroupID("g-perf"), name: "Perf", color: .yellow, workspaces: [ws("tab", "Tab switch")])
        perf.parent = GroupID("g-panes")
        return [SidebarSection(kind: .machine(machine), nodes: [
            .workspace(ws("cef", "Slimmer CEF bundle")),
            .workspace(SidebarWorkspace(id: WorkspaceID("w-rocket"), title: "Ship it", icon: .emoji("🚀"))),
            .group(app),
            .group(SidebarGroup(id: GroupID("g-panes"), name: "Panes & layout", color: .cyan, workspaces: [
                ws("split", "Split spring", tabs: [SidebarTab(id: TabID("split-terminal"), title: "terminal")]),
            ])),
            .group(perf),
            .workspace(ws("loose", "New Chief shows in Home")),
        ])]
    }

    static func render(density: SidebarDensity, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let saved = DesignSettings.shared.sidebarSections.density
        DesignSettings.shared.sidebarSections.density = density
        defer { DesignSettings.shared.sidebarSections.density = saved }
        let width: CGFloat = 280, height: CGFloat = 420
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        let theme = dark ? "Soft Blue" : "Soft Blue Light"
        let input = try AANestedGroupsGalleryTests.input(theme)
        _ = ThemeScope.app.store.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(theme), input: input, animated: false)
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor
        let model = SidebarModel(sections: sections())
        model.expanded = density == .expanded
        let list = SidebarListView(model: model)
        list.frame = NSRect(x: 0, y: 0, width: width, height: height)
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        list.frame.origin.y = height - list.frame.height
        list.setHovered(hovered)
        root.layoutSubtreeIfNeeded()
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
    func renderGallery() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "sidebar-look-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var images: [CGImage] = []
        for dark in [true, false] {
            for density in SidebarDensity.allCases {
                let image = try Self.render(density: density, dark: dark)
                images.append(image)
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(dark ? "dark" : "light")-\(density.rawValue).png"))
            }
        }
        let columns = SidebarDensity.allCases.count
        let w = images[0].width, h = images[0].height, gap = 16
        let ctx = try #require(CGContext(data: nil, width: columns * w + (columns - 1) * gap, height: 2 * h + gap, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (i, image) in images.enumerated() {
            let col = i % columns, row = i / columns
            ctx.draw(image, in: CGRect(x: col * (w + gap), y: (1 - row) * (h + gap), width: w, height: h))
        }
        try AAGroupHeaderDensityGalleryTests.write(try #require(ctx.makeImage()), to: out.appending(path: "all.png"))
        for dark in [true, false] {
            for density in SidebarDensity.allCases {
                for minimal in [SidebarMinimalMode.off, .both] {
                    let image = try Self.renderTrailingColumn(density: density, minimal: minimal, dark: dark)
                    let name = "trailing-\(dark ? "dark" : "light")-\(density.rawValue)-minimal-\(minimal.rawValue).png"
                    try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: name))
                }
            }
        }
        for dark in [true, false] {
            let image = try Self.renderStatusColors(dark: dark)
            try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "status-\(dark ? "dark" : "light").png"))
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "sidebar-look-gallery.tar", "sidebar-look-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }

    /// Lawrence msg 11914 and 11959: "trailing dots and spinners must line up horizontally across sections".
    /// The `SidebarTrailingColumnTests` fixture (Home unread, a selected band item that needs you, the band's
    /// pinned loading group header, selected, unread, busy and nested rows, open and loading headers at
    /// several depths; the unread row hovered) at every density, Minimal Mode off and on, dark and light,
    /// with a 1 px guide line down the trailing column (the open group header chevron's center x).
    /// `renderGallery` writes them as `trailing-<appearance>-<density>-minimal-<mode>.png`.
    static func renderTrailingColumn(density: SidebarDensity, minimal: SidebarMinimalMode, dark: Bool) throws -> CGImage {
        var image: CGImage?
        try SidebarGroupRailAlignmentTests.with(density, minimal) {
            let h = SidebarTrailingColumnTests.KindHarness(width: 300)
            defer { h.window.close() }
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
            h.list.setHovered(.workspace(SidebarTrailingColumnTests.unread))
            for view in AANestedGroupsGalleryTests.all(root) {
                view.needsLayout = true
                view.layoutSubtreeIfNeeded()
                view.layer?.removeAllAnimations()
                view.needsDisplay = true
                view.displayIfNeeded()
            }
            CATransaction.flush()
            let column = root.convert(NSPoint(x: try SidebarTrailingColumnTests.columnX(h), y: 0), from: h.list).x
            let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: rep)
            let shot = try #require(rep.cgImage)
            let scale = CGFloat(shot.width) / root.bounds.width
            let ctx = try #require(CGContext(data: nil, width: shot.width, height: shot.height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(shot, in: CGRect(x: 0, y: 0, width: shot.width, height: shot.height))
            // One device pixel wide, centered on the column x.
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 0.85))
            ctx.fill(CGRect(x: (column * scale).rounded(.down), y: 0, width: 1, height: CGFloat(shot.height)))
            image = ctx.makeImage()
        }
        return try #require(image)
    }

    /// Lawrence msg 11983: "make sure sidebar has blue, orange/yellow for needs attention, and red for errors".
    /// The `SidebarStatusColorTests` fixture (Home unread, band items waiting and failed, rows unread, needing
    /// permission and failed, open and collapsed group headers rolling up their members) at the default density.
    static func renderStatusColors(dark: Bool) throws -> CGImage {
        let h = SidebarStatusColorTests.Harness(dark: dark)
        defer { h.window.close() }
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
        for view in AANestedGroupsGalleryTests.all(root) {
            view.needsLayout = true
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
}
