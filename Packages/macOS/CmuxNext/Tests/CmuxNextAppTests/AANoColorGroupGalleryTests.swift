import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// Every `sidebar.noColorGroup` look side by side (Leo 2026-11-05: "you might as well have it be at least slightly
/// distinguishing from, like, literally depicting it as if it were unhovered"): loose rows, an open group with no
/// color (one member selected, one hovered), a collapsed one, and a blue group for comparison, dark on top, light
/// below, one column per look (`plain` is the look before). Written under `no-color-group-gallery/` with `all.png`,
/// bundled to `no-color-group-gallery.tar` for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AANoColorGroupGalleryTests {
    static let looks: [SidebarNoColorGroupLook] = [.plain, .tray, .glass, .lit]
    static let hovered = SidebarRowKey.workspace(WorkspaceID("n-hover"))

    static func sections() -> [SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        func ws(_ id: String, _ title: String, busy: Bool = false) -> SidebarWorkspace {
            SidebarWorkspace(id: WorkspaceID("n-\(id)"), title: title, activity: busy ? .busy(progress: nil) : .idle)
        }
        let plain = SidebarGroup(id: GroupID("g-none"), name: "Research", custom: GroupTint.noneWire, workspaces: [
            ws("read", "Read the RFC"), ws("select", "Selected member", busy: true), ws("hover", "Hovered member"), ws("notes", "Notes"),
        ])
        let folded = SidebarGroup(id: GroupID("g-none-folded"), name: "Folded, no color", custom: GroupTint.noneWire, isCollapsed: true,
                                  workspaces: [ws("f", "hidden")])
        let blue = SidebarGroup(id: GroupID("g-blue"), name: "Blue group", color: .blue, workspaces: [ws("b1", "Colored member")])
        return [SidebarSection(kind: .machine(machine), nodes: [
            .workspace(ws("loose", "Ungrouped row")),
            .group(plain),
            .workspace(ws("loose2", "Another ungrouped row")),
            .group(folded),
            .group(blue),
        ])]
    }

    static func render(_ look: SidebarNoColorGroupLook, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        let key = SidebarNoColorGroupLook.tunable.key
        TunableStore.shared.set(key, look.tunableValue)
        defer { TunableStore.shared.set(key, nil) }
        let width: CGFloat = 260, height: CGFloat = 330
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
            for look in Self.looks {
                let image = try Self.render(look, dark: dark)
                images.append(image)
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(dark ? "dark" : "light")-\(look.rawValue).png"))
            }
        }
        let columns = Self.looks.count
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
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "no-color-group-gallery.tar", "no-color-group-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
