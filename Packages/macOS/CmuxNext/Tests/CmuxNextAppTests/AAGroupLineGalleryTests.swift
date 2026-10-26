import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxTheme
import Foundation
import Testing

/// The `sidebar.groupLineLayout` gallery (Leo 2026-10-23, "WTF HAPPENED TO FOLLOWING CHROME"): the real sidebar list
/// drawn offscreen in each layout, light and dark (Soft Blue), with an open group (a member selected), a subgroup and a
/// collapsed group. Written as PNGs under `group-line-gallery/` in the package and bundled to `group-line-gallery.tar`
/// for `cmux-ci run --artifact`. Runs only with `CMUX_TEST_REQUIRE_GUI=1`.
@MainActor @Suite(.serialized) struct AAGroupLineGalleryTests {
    static func sections() -> [SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        func ws(_ id: String) -> SidebarWorkspace { SidebarWorkspace(id: WorkspaceID(id), title: id) }
        let fleet = SidebarGroup(id: GroupID("g-fleet"), name: "Agent fleet (build-box)", color: .purple,
                                 workspaces: ["cx-ascii", "cx-acp", "cx-chrome"].map(ws))
        var perf = SidebarGroup(id: GroupID("g-perf"), name: "Perf", color: .blue, workspaces: ["sidebar-scroll", "tab-switch"].map(ws))
        perf.parent = fleet.id
        perf.depth = 1
        let design = SidebarGroup(id: GroupID("g-design"), name: "Design", color: .pink, isCollapsed: true,
                                  workspaces: ["icons", "tokens"].map(ws))
        let tail = SidebarGroup(id: GroupID("g-ci"), name: "Nightly & CI", color: .green, workspaces: ["nightly", "land-train"].map(ws))
        return [SidebarSection(kind: .machine(machine), nodes: [
            .workspace(ws("scratch")), .workspace(ws("notes")), .group(fleet), .group(perf), .group(design), .group(tail),
        ])]
    }

    static func render(theme: String, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let width: CGFloat = 260, height: CGFloat = 420
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
        let list = SidebarListView(model: SidebarModel(sections: sections(), activeWorkspaceID: WorkspaceID("cx-acp")))
        list.frame = NSRect(x: 0, y: 0, width: width, height: height)
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        list.frame.origin.y = height - list.frame.height // the root is not flipped: pin the list to the top
        root.layoutSubtreeIfNeeded()
        for view in AANestedGroupsGalleryTests.all(root) { view.needsDisplay = true; view.displayIfNeeded() }
        CATransaction.flush()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let image = try #require(rep.cgImage)
        window.close()
        return image
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let out = AANestedGroupsGalleryTests.packageRoot.appending(path: "group-line-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for layout in SidebarGroupLineLayout.allCases {
            try SidebarGroupLineLayoutTests.withLayout(layout) {
                for (mode, theme, dark) in [("light", "Soft Blue Light", false), ("dark", "Soft Blue", true)] {
                    let image = try Self.render(theme: theme, dark: dark)
                    let url = out.appending(path: "\(layout.rawValue)-\(mode).png")
                    let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
                    CGImageDestinationAddImage(dest, image, nil)
                    #expect(CGImageDestinationFinalize(dest))
                }
            }
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = AANestedGroupsGalleryTests.packageRoot
        tar.arguments = ["cf", "group-line-gallery.tar", "group-line-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
