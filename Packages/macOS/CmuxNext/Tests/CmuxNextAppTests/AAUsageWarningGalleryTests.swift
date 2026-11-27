import AppKit
@testable import CmuxNextAgentLanes
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxTheme
import CmuxNextTestSupport
import Foundation
import Testing

/// Stills of a runaway session's rows (`SidebarUsageWarningTests`), light and dark: the real sidebar list mapped from
/// four agent chats (working, waiting, failed, idle) through the real lane status, before (no acpmux `usageWarnings`)
/// and after (the working chat breaks both rules). The two match: no row draws a warning triangle (Leo 2026-11-22:
/// "i literally said to remove this bullshit over 24 hours ago."). Written under `usage-warning-gallery/` in the
/// package and bundled to `usage-warning-gallery.tar` for `cmux-ci run --artifact`; each still is also printed base64
/// between `USAGE-WARNING-PNG` lines, so a run's log carries it.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAUsageWarningGalleryTests {
    static let packageRoot = AANestedGroupsGalleryTests.packageRoot

    private static func sections(warns: Bool) throws -> [SidebarSection] {
        let fixture = try SidebarLaneStatusTests.Fixture()
        _ = try SidebarUsageWarningTests.workingRow(fixture, warned: warns)
        return fixture.sections()
    }

    private static func sidebar(warns: Bool, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let width: CGFloat = 280, height: CGFloat = 140
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
        let list = SidebarListView(model: SidebarModel(sections: try sections(warns: warns)))
        list.frame = NSRect(x: 0, y: 0, width: width, height: height)
        root.addSubview(list)
        list.reload(animated: false)
        list.frame.origin.y = height - list.frame.height
        root.layoutSubtreeIfNeeded()
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
        let out = Self.packageRoot.appending(path: "usage-warning-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (mode, dark) in [("light", false), ("dark", true)] {
            for (name, warns) in [("before", false), ("after", true)] {
                let url = out.appending(path: "sidebar-\(name)-\(mode).png")
                let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
                CGImageDestinationAddImage(dest, try Self.sidebar(warns: warns, dark: dark), nil)
                #expect(CGImageDestinationFinalize(dest))
                let png = try Data(contentsOf: url).base64EncodedString()
                print("USAGE-WARNING-PNG \(url.lastPathComponent)\n\(png)\nUSAGE-WARNING-PNG end")
            }
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = Self.packageRoot
        tar.arguments = ["cf", "usage-warning-gallery.tar", "usage-warning-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
