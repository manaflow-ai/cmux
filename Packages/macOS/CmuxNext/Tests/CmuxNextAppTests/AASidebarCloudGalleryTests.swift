import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxTheme
import Foundation
import Testing

/// Capture-only (never in a PR): the real sidebar list drawn offscreen with this Mac's agent groups and four Cloud
/// machines made from one image (three share its workspace id), as in Leo's 2026-10-29 capture. PNGs under
/// `sidebar-cloud-gallery/`, bundled to `sidebar-cloud-gallery.tar` for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized) struct AASidebarCloudGalleryTests {
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let repoRoot = packageRoot.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func input(_ name: String) throws -> ThemeInput {
        let text = try String(contentsOf: repoRoot.appending(path: "Resources/cmux-themes/\(name)"), encoding: .utf8)
        let file = try #require(ThemeFileColors(name: name, themeFile: text))
        var input = ThemeInput(background: file.background, foreground: file.foreground, palette: file.palette.compactMap { $0 },
                               selectionBackground: file.selectionBackground, selectionForeground: file.selectionForeground)
        input.accentColor = file.accent
        return input
    }

    /// A Cloud machine's daemon as the image leaves it: one unnamed workspace with an idle shell at `/home/cmux`, mapped
    /// as the app maps it (the auto name gives an idle shell its folder's name; an untitled tab shows its folder).
    static func cloud(_ name: String, workspace: String) -> SidebarRowSection {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, focusedAt: 1, tabs: [TabSnapshot(surface: 1, title: "", cwd: "/home/cmux")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: WorkspaceKey(rawValue: workspace),
                                                                        name: "workspace-1", screens: [screen])]))
        let machine = SidebarMachine(id: MachineID(name), name: name, kind: .cloud)
        let mapped = SidebarMapping.shared.sections(store.sidebarSections, machine: machine,
                                                    pageFace: { _, tab, _ in .init(title: tab.cwd.map { String($0.split(separator: "/").last ?? "") }, favicon: nil) },
                                                    tabTitle: { TabItemMapping.shared.title($0, fallbackTitle: "Terminal") }, terminalTitle: "Terminal")
        return SidebarRowSection(kind: .machine(machine), nodes: mapped.first?.nodes ?? [])
    }

    static func sections(shared: Bool) -> [SidebarRowSection] {
        let agents = ["ui-tank-visual-rule", "ui-tank-visual-check"].map {
            SidebarWorkspace(id: WorkspaceID("ws_\($0)"), title: $0, agentWorking: true)
        }
        let group = SidebarGroup(id: GroupID("grp_tank"), name: "UI think tank", color: .blue, workspaces: agents)
        let local = SidebarRowSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)),
                                   nodes: [.group(group), .workspace(SidebarWorkspace(id: WorkspaceID("ws_coord"), title: "cmux NEXT coordinator"))])
        let ids = shared ? ["ws_image", "ws_image", "ws_peer", "ws_image"] : ["ws_a", "ws_b", "ws_c", "ws_d"]
        let pinned = SidebarRowSection(kind: .custom(SidebarCustomSection(id: "pinned", title: "Pinned", showsTitle: true)),
                                       nodes: [.workspace(SidebarWorkspace(id: WorkspaceID("ws_pinned_deploy"), machineID: MachineID("build-vm"),
                                                                           title: "deploy"))])
        return [pinned, local] + zip(["build-vm", "scratch-vm", "dev-vm", "scratch-vm-2"], ids).map { cloud($0, workspace: $1) }
    }

    static func render(theme: String, dark: Bool, shared: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let width: CGFloat = 300, height: CGFloat = 420
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        _ = ThemeScope.app.store.apply(try input(theme))
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(theme), input: try input(theme), animated: false)
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor
        let model = SidebarModel(sections: sections(shared: shared))
        let list = SidebarListView(model: model)
        list.frame = NSRect(x: 0, y: 0, width: width, height: height)
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        list.frame.origin.y = height - list.frame.height
        root.layoutSubtreeIfNeeded()
        // 2x: every layer draws at Retina scale, into a bitmap twice the view's size.
        func retina(_ layer: CALayer) { layer.contentsScale = 2; layer.setNeedsDisplay(); layer.sublayers?.forEach(retina) }
        for view in Self.all(root) { if let layer = view.layer { retina(layer) }; view.needsDisplay = true; view.displayIfNeeded() }
        CATransaction.flush()
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width) * 2, pixelsHigh: Int(height) * 2,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = root.bounds.size
        root.cacheDisplay(in: root.bounds, to: rep)
        let image = try #require(rep.cgImage)
        // The measured rows, for the PR's table.
        var lines = ""
        for row in list.displayed.rows { lines += "\(row.key)\ty=\(row.y)\th=\(row.height)\n" }
        try lines.write(to: packageRoot.appending(path: "sidebar-cloud-gallery/rows-\(shared ? "image-ids" : "own-ids")-\(dark ? "dark" : "light").tsv"), atomically: true, encoding: .utf8)
        window.close()
        return image
    }

    static func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let out = Self.packageRoot.appending(path: "sidebar-cloud-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for shared in [true, false] {
        for (mode, theme, dark) in [("light", "Soft Blue Light", false), ("dark", "Soft Blue", true)] {
            let image = try Self.render(theme: theme, dark: dark, shared: shared)
            let url = out.appending(path: "cloud-rows-\(shared ? "image-ids" : "own-ids")-\(mode).png")
            let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(dest, image, nil)
            #expect(CGImageDestinationFinalize(dest))
        }
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = Self.packageRoot
        tar.arguments = ["cf", "sidebar-cloud-gallery.tar", "sidebar-cloud-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
