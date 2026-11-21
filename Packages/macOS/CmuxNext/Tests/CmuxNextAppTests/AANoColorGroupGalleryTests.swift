import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import QuartzCore
import Testing

/// Group headers as glass, side by side with today's look, over a busy wallpaper behind a translucent sidebar (Leo
/// 2026-11-05: "We can afford to put glass here, so why the f*** do we not have glass for this? ... still keeping the
/// colors, it's just, like, but just make it glassier", "Why is it just one solid opaque block? Why does it not have
/// any sort of rim at all?", and on no color: "you might as well have it be at least slightly distinguishing from,
/// like, literally depicting it as if it were unhovered"). Columns: today (the solid bar, an uncolored group drawn as
/// plain rows), then `sidebar.groupGlass` glass, vivid and frost with the uncolored group as untinted glass. Rows:
/// dark on top, light below. The fixture: loose rows, red, blue, purple and green groups, an open group with no
/// color (one member selected, one hovered) and a collapsed one. Written under `no-color-group-gallery/` with
/// `all.png`, bundled to `no-color-group-gallery.tar` for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AANoColorGroupGalleryTests {
    struct Column {
        var name: String
        var glass: SidebarGroupGlass
        var noColor: SidebarNoColorGroupLook
    }

    static let columns = [
        Column(name: "today", glass: .solid, noColor: .plain),
        Column(name: "glass", glass: .glass, noColor: .glass),
        Column(name: "vivid", glass: .vivid, noColor: .glass),
        Column(name: "frost", glass: .frost, noColor: .glass),
    ]
    static let hovered = SidebarRowKey.workspace(WorkspaceID("n-hover"))

    static func sections() -> [SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        func ws(_ id: String, _ title: String, busy: Bool = false) -> SidebarWorkspace {
            SidebarWorkspace(id: WorkspaceID("n-\(id)"), title: title, activity: busy ? .busy(progress: nil) : .idle)
        }
        func group(_ id: String, _ name: String, _ color: GroupColor, _ members: [SidebarWorkspace]) -> SidebarNode {
            .group(SidebarGroup(id: GroupID("g-\(id)"), name: name, color: color, workspaces: members))
        }
        let plain = SidebarGroup(id: GroupID("g-none"), name: "Research", custom: GroupTint.noneWire, workspaces: [
            ws("read", "Read the RFC"), ws("select", "Selected member", busy: true), ws("hover", "Hovered member"),
        ])
        let folded = SidebarGroup(id: GroupID("g-none-folded"), name: "Folded, no color", custom: GroupTint.noneWire, isCollapsed: true,
                                  workspaces: [ws("f", "hidden")])
        return [SidebarSection(kind: .machine(machine), nodes: [
            .workspace(ws("loose", "workspace-392")),
            group("leads", "Leads", .red, [ws("l1", "Launching cloud-devbuild", busy: true), ws("l2", "workspace-394")]),
            group("agents", "Agents", .purple, [ws("a1", "transcript-like-claude-desktop"), ws("a2", "smooth-under-load", busy: true)]),
            .group(plain),
            group("perf", "Perf", .blue, [ws("p1", "Tab switch")]),
            group("ship", "Ship", .green, [ws("s1", "Release notes")]),
            .group(folded),
            .workspace(ws("loose2", "ui-composer-menus")),
        ])]
    }

    /// A busy, saturated wallpaper (a riced desktop) the translucent sidebar sits over.
    static func wallpaper(_ bounds: CGRect, dark: Bool) -> CALayer {
        let wall = CAGradientLayer()
        wall.frame = bounds
        wall.startPoint = CGPoint(x: 0, y: 0)
        wall.endPoint = CGPoint(x: 1, y: 1)
        let colors: [UInt32] = dark ? [0x2B1650, 0xC2185B, 0x0F766E, 0xF59E0B, 0x1E3A8A] : [0xFBCFE8, 0x99F6E4, 0xFDE68A, 0xC4B5FD, 0xBAE6FD]
        wall.colors = colors.map { ThemeRGB(hex: $0).cgColor }
        for (i, hex) in [0xEF4444, 0x22D3EE, 0xA3E635, 0xE879F9].enumerated() {
            let blob = CALayer()
            let side = bounds.width * 0.55
            blob.frame = CGRect(x: CGFloat(i % 2) * bounds.width * 0.5 - side * 0.2, y: CGFloat(i) * bounds.height * 0.24, width: side, height: side)
            blob.cornerRadius = side / 2
            blob.backgroundColor = ThemeRGB(hex: UInt32(hex)).withAlpha(dark ? 0.55 : 0.45).cgColor
            wall.addSublayer(blob)
        }
        return wall
    }

    static func render(_ column: Column, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        let keys = [SidebarGroupGlass.tunable.key, SidebarNoColorGroupLook.tunable.key]
        TunableStore.shared.set(keys[0], column.glass.tunableValue)
        TunableStore.shared.set(keys[1], column.noColor.tunableValue)
        defer { keys.forEach { TunableStore.shared.set($0, nil) } }
        let width: CGFloat = 270, height: CGFloat = 470
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
        root.layer?.addSublayer(Self.wallpaper(root.bounds, dark: dark))
        // The sidebar's own translucency over the wallpaper.
        let veil = CALayer()
        veil.frame = root.bounds
        veil.backgroundColor = scope.perform { Palette.sidebarBackground.withAlphaComponent(0.62) }.cgColor
        root.layer?.addSublayer(veil)
        let model = SidebarModel(sections: sections(), activeWorkspaceID: WorkspaceID("n-select"))
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
        let out = root.appending(path: "no-color-group-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var images: [CGImage] = []
        for dark in [true, false] {
            for column in Self.columns {
                let image = try Self.render(column, dark: dark)
                images.append(image)
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(dark ? "dark" : "light")-\(column.name).png"))
            }
        }
        let count = Self.columns.count
        let w = images[0].width, h = images[0].height, gap = 16
        let ctx = try #require(CGContext(data: nil, width: count * w + (count - 1) * gap, height: 2 * h + gap, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (i, image) in images.enumerated() {
            let col = i % count, row = i / count
            ctx.draw(image, in: CGRect(x: col * (w + gap), y: (1 - row) * (h + gap), width: w, height: h))
        }
        try AAGroupHeaderDensityGalleryTests.write(try #require(ctx.makeImage()), to: out.appending(path: "all.png"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "no-color-group-gallery.tar", "no-color-group-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
