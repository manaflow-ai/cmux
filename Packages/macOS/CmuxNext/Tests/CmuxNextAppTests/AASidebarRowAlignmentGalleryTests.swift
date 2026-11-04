import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// Before/after shots for the group row alignment fix (Lawrence 2026-10-30, "alignment here is bad"; "triangle not
/// aligned"): the real sidebar list drawn offscreen, light and dark, with an open group like the NIGHTLY "Sleep alarm"
/// one and rows whose spinners stack over a usage-warning triangle. Written as PNGs under `row-alignment-gallery/` in
/// the package and bundled to `row-alignment-gallery.tar` for `cmux-ci run --artifact`. Runs only with
/// `CMUX_TEST_REQUIRE_GUI=1`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AASidebarRowAlignmentGalleryTests {
    static func sections() -> [SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        func working(_ id: String) -> SidebarWorkspace {
            SidebarWorkspace(id: WorkspaceID(id), title: id, lastActivity: Date(), agentWorking: true, kind: .harness, activity: .working)
        }
        var warned = SidebarWorkspace(id: WorkspaceID("Acpmux session timeout"), title: "Acpmux session timeout",
                                      lastActivity: Date(), kind: .harness)
        warned.usageWarnings = ["90 subagents started in the last hour, above 40"]
        let alarm = SidebarGroup(id: GroupID("g-alarm"), name: "Sleep alarm", color: .purple,
                                 workspaces: [SidebarWorkspace(id: WorkspaceID("New Workspace"), title: "New Workspace")])
        let fleet = SidebarGroup(id: GroupID("g-settings"), name: "Settings", color: .blue,
                                 workspaces: ["Settings sections refactor", "Theme highlight"].map { SidebarWorkspace(id: WorkspaceID($0), title: $0) })
        return [SidebarSection(kind: .machine(machine), nodes: [
            .workspace(working("Sidebar group row alignment")), .workspace(working("NIGHTLY crash log")),
            .workspace(working("Latest Chromium CEF")), .workspace(warned),
            .group(alarm), .group(fleet),
        ])]
    }

    static func render(theme: String, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let width: CGFloat = 280, height: CGFloat = 300
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
        let list = SidebarListView(model: SidebarModel(sections: sections()))
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
        let out = AANestedGroupsGalleryTests.packageRoot.appending(path: "row-alignment-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for density in SidebarDensity.allCases {
            try SidebarGroupRailAlignmentTests.with(density, .off) {
                for (mode, theme, dark) in [("light", "Soft Blue Light", false), ("dark", "Soft Blue", true)] {
                    let image = try Self.render(theme: theme, dark: dark)
                    let url = out.appending(path: "\(density.rawValue)-\(mode).png")
                    let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
                    CGImageDestinationAddImage(dest, image, nil)
                    #expect(CGImageDestinationFinalize(dest))
                }
            }
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = AANestedGroupsGalleryTests.packageRoot
        tar.arguments = ["cf", "row-alignment-gallery.tar", "row-alignment-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
