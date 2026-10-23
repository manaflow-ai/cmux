import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxTheme
import Foundation
import Testing

/// The row close corner's gallery (`sidebar.closeNotch`, Leo 2026-10-22): every look, a hovered row and
/// a hovered selected row, light and dark, drawn from the real list offscreen with the shipped Soft Blue
/// themes. Written as PNGs under `close-notch-gallery/` in the package and bundled to
/// `close-notch-gallery.tar` for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized) struct WorkspaceRowCloseNotchGalleryTests {
    static let titles = ["Release checklist", "a workspace whose name runs to the end of its row", "Notes"]

    static func render(_ look: SidebarCloseNotch, hoverSelected: Bool, theme: String, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        try #require(TunableStore.shared.set(SidebarCloseNotch.tunable.key, look.tunableValue) == look.tunableValue)
        // The watch drops its cached values one main-actor hop after a set; rows made in this turn
        // would read the last look.
        SidebarTunablesWatch.shared.changed()
        let width: CGFloat = 240, height: CGFloat = 120
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        let input = try AANestedGroupsGalleryTests.input(theme)
        _ = ThemeStore.shared.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(theme), input: input, animated: false)
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor
        let workspaces = titles.enumerated().map { SidebarWorkspace(id: WorkspaceID("ws-\($0.offset)"), title: $0.element) }
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let list = SidebarListView(model: SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: workspaces.map { .workspace($0) })]))
        list.contextMenuProvider = { _ in NSMenu() }
        list.frame = NSRect(x: 0, y: 0, width: width, height: height)
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        list.frame.origin.y = height - list.frame.height
        let selected = try #require(list.rowViews[.workspace(workspaces[0].id)])
        selected.isSelected = true
        let hovered = workspaces[hoverSelected ? 0 : 1].id
        list.setHovered(.workspace(hovered))
        root.layoutSubtreeIfNeeded()
        let row = try #require(list.rowViews[.workspace(hovered)] as? WorkspaceRowView)
        try #require(row.closeNotchLook == look && row.closeNotch == look, "the \(look) still draws the \(row.closeNotchLook) cut")
        for view in AANestedGroupsGalleryTests.all(root) { view.needsDisplay = true; view.displayIfNeeded() }
        CATransaction.flush()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let image = try #require(rep.cgImage)
        window.close()
        return image
    }

    /// Runs only with `CMUX_TEST_REQUIRE_GUI` set (the fleet's opt-in for drawing tests): it writes files.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        defer {
            TunableStore.shared.set(SidebarCloseNotch.tunable.key, nil)
            SidebarTunablesWatch.shared.changed()
        }
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "close-notch-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for look in SidebarCloseNotch.allCases {
            for (state, hoverSelected) in [("hover", false), ("selected-hover", true)] {
                for (mode, theme, dark) in [("light", "Soft Blue Light", false), ("dark", "Soft Blue", true)] {
                    let image = try Self.render(look, hoverSelected: hoverSelected, theme: theme, dark: dark)
                    let url = out.appending(path: "\(look.rawValue)-\(state)-\(mode).png")
                    let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
                    CGImageDestinationAddImage(dest, image, nil)
                    #expect(CGImageDestinationFinalize(dest))
                }
            }
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "close-notch-gallery.tar", "close-notch-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
