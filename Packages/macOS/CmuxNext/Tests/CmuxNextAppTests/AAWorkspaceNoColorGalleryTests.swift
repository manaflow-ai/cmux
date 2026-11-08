import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// Stills of the No Color work (Lawrence 2026-10-22: "need to be able to remove all workspace
/// colors"), light and dark: the real sidebar list with colors on, the same list with one group
/// set to no color, the list with `sidebar.showColors` off, and the workspace and group menu
/// headers whose swatches start with No Color. Written under `ws-no-color-gallery/` in the package
/// and bundled to `ws-no-color-gallery.tar` for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAWorkspaceNoColorGalleryTests {
    static let packageRoot = AANestedGroupsGalleryTests.packageRoot

    private static func sections(groupNone: Bool) -> [SidebarSection] {
        var docs = CmuxNextSidebar.SidebarGroup(id: GroupID("docs"), name: "Docs", color: .green, workspaces: [
            SidebarWorkspace(id: WorkspaceID("d1"), title: "Write the release notes"),
        ])
        if groupNone { docs.tint = GroupTint.none }
        return [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [
            .group(CmuxNextSidebar.SidebarGroup(id: GroupID("rift"), name: "Try Rift workspaces", color: .red, workspaces: [
                SidebarWorkspace(id: WorkspaceID("r1"), title: "Every subagent in a VM", icon: .swatch(.blue)),
                SidebarWorkspace(id: WorkspaceID("r2"), title: "Chief sees attached images", icon: .symbol("star.fill", tint: .orange)),
            ])),
            .group(docs),
            .workspace(SidebarWorkspace(id: WorkspaceID("w1"), title: "Agent ids always linked", icon: .swatch(.purple))),
            .workspace(SidebarWorkspace(id: WorkspaceID("w2"), title: "Ship it", icon: .emoji("🚀", chip: .cyan))),
        ])]
    }

    /// A themed offscreen window holding `content` (sized by the caller), drawn to an image.
    private static func draw(width: CGFloat, height: CGFloat, dark: Bool, _ content: (NSView, ThemeScope) throws -> Void) throws -> CGImage {
        _ = NSApplication.shared
        let theme = dark ? "Soft Blue" : "Soft Blue Light"
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
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
        window.orderFrontRegardless()
        try content(root, scope)
        root.layoutSubtreeIfNeeded()
        for view in AANestedGroupsGalleryTests.all(root) { view.needsDisplay = true; view.displayIfNeeded() }
        CATransaction.flush()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let image = try #require(rep.cgImage)
        window.close()
        return image
    }

    private static func sidebar(groupNone: Bool, showsColors: Bool, dark: Bool) throws -> CGImage {
        let width: CGFloat = 280, height: CGFloat = 260
        return try draw(width: width, height: height, dark: dark) { root, _ in
            let model = SidebarModel(sections: sections(groupNone: groupNone))
            model.showsColors = showsColors
            let list = SidebarListView(model: model)
            list.frame = NSRect(x: 0, y: 0, width: width, height: height)
            root.addSubview(list)
            list.reload(animated: false)
            list.frame.origin.y = height - list.frame.height
        }
    }

    private static func header(group: Bool, dark: Bool) throws -> CGImage {
        let registry = ActionRegistry.standard()
        let menu: NSMenu
        let target: ActionTargetRef
        if group {
            target = ActionTargetRef(kind: .workspaceGroup, id: "g")
            menu = registry.makeContextMenu(for: .workspaceGroup, target: target)
            MenuIdentityHeader.install(in: menu, registry: registry, target: target, name: "Try Rift workspaces",
                                       rename: "workspaceGroup.rename", noColor: true)
        } else {
            target = ActionTargetRef(kind: .workspace, id: "ws")
            registry.bind("renameWorkspace", invoke: { _ in })
            registry.bind("palette.workspaceColor", invoke: { _ in })
            registry.bind("palette.resetWorkspaceColor", invoke: { _ in })
            menu = registry.makeContextMenu(for: .workspaceRow, target: target)
            MenuIdentityHeader.install(in: menu, registry: registry, target: target, name: "Every subagent in a VM", rename: "renameWorkspace")
        }
        let view = try #require(menu.items.first?.view as? MenuIdentityHeaderView)
        menu.removeItem(at: 0)
        let width = max(view.frame.width, 300), height = view.frame.height + 16
        return try draw(width: width, height: height, dark: dark) { root, scope in
            view.adoptMenuScope(scope)
            view.frame = NSRect(x: 0, y: 8, width: width, height: view.frame.height)
            root.addSubview(view)
        }
    }

    /// Runs only with `CMUX_TEST_REQUIRE_GUI` set (the fleet's opt-in for drawing tests): it writes files.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let out = Self.packageRoot.appending(path: "ws-no-color-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (mode, dark) in [("light", false), ("dark", true)] {
            let stills: [(String, CGImage)] = [
                ("sidebar-colors-on", try Self.sidebar(groupNone: false, showsColors: true, dark: dark)),
                ("sidebar-docs-no-color", try Self.sidebar(groupNone: true, showsColors: true, dark: dark)),
                ("sidebar-show-colors-off", try Self.sidebar(groupNone: false, showsColors: false, dark: dark)),
                ("menu-header-workspace", try Self.header(group: false, dark: dark)),
                ("menu-header-group-no-color", try Self.header(group: true, dark: dark)),
            ]
            for (name, image) in stills {
                let url = out.appending(path: "\(name)-\(mode).png")
                let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
                CGImageDestinationAddImage(dest, image, nil)
                #expect(CGImageDestinationFinalize(dest))
            }
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = Self.packageRoot
        tar.arguments = ["cf", "ws-no-color-gallery.tar", "ws-no-color-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
