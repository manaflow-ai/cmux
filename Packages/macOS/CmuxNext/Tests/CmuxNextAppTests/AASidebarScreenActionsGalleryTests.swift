import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import ImageIO
import Testing

/// Three sidebar widths, in light/dark and flat/grouped layouts. These are the mounted list rows,
/// including long machine/project names, local Share, Mac/Cloud View, offline Mac, and Linux SSH.
@MainActor @Suite(.serialized, .closesItsWindows) struct AASidebarScreenActionsGalleryTests {
    static func render(width: CGFloat, grouped: Bool, theme: String, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let height: CGFloat = 640
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
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
        let model = SidebarModel(sections: SidebarScreenActionTests.examples)
        model.groupsByComputer = grouped
        let list = SidebarListView(model: model)
        list.contextMenuProvider = { _ in NSMenu() }
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        list.frame.origin.y = height - list.frame.height
        root.layoutSubtreeIfNeeded()
        // One hovered Mac beside resting Cloud/offline rows captures the primary action and
        // the existing secondary controls together, at each width and appearance.
        let hovered = grouped ? list.rowViews[.section(.machine(MachineID("mac")))] : list.rowViews[.workspace(WorkspaceID("ws-mac"))]
        hovered?.isHovered = true
        hovered?.needsLayout = true
        root.layoutSubtreeIfNeeded()
        for view in AANestedGroupsGalleryTests.all(root) { view.needsDisplay = true; view.displayIfNeeded() }
        CATransaction.flush()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        return try #require(rep.cgImage)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let out = AANestedGroupsGalleryTests.packageRoot.appending(path: "sidebar-screen-actions-gallery")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for width: CGFloat in [240, 300, 360] {
            for grouped in [false, true] {
                for (mode, theme, dark) in [("light", "Soft Blue Light", false), ("dark", "Soft Blue", true)] {
                    let image = try Self.render(width: width, grouped: grouped, theme: theme, dark: dark)
                    let name = "\(Int(width))-\(grouped ? "grouped" : "flat")-\(mode).png"
                    let dest = try #require(CGImageDestinationCreateWithURL(out.appending(path: name) as CFURL, "public.png" as CFString, 1, nil))
                    CGImageDestinationAddImage(dest, image, nil)
                    #expect(CGImageDestinationFinalize(dest))
                }
            }
        }
    }
}
