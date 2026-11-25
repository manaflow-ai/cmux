import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// The nested-groups prototype's stills (light and dark, every `SidebarNestedFixture` scenario): the real
/// sidebar list views drawn offscreen with the shipped Soft Blue themes, written as PNGs under
/// `nested-groups-gallery/` in the package and bundled to `nested-groups-gallery.tar` for `cmux-ci run
/// --artifact`. The suite's file name sorts first so a 64-shard fleet step 1/64 runs it alone.
@MainActor @Suite(.serialized, .closesItsWindows) struct AANestedGroupsGalleryTests {
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let repoRoot = packageRoot.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func input(_ name: String) throws -> ThemeInput {
        // cmux's own themes, else Ghostty's bundled ones (Apple System Colors lives there, #30232's gallery).
        let own = repoRoot.appending(path: "Resources/cmux-themes/\(name)")
        let path = FileManager.default.fileExists(atPath: own.path) ? own : repoRoot.appending(path: "Resources/ghostty/themes/\(name)")
        let text = try String(contentsOf: path, encoding: .utf8)
        let file = try #require(ThemeFileColors(name: name, themeFile: text))
        var input = ThemeInput(background: file.background, foreground: file.foreground, palette: file.palette.compactMap { $0 },
                               selectionBackground: file.selectionBackground, selectionForeground: file.selectionForeground)
        input.accentColor = file.accent
        return input
    }

    static func render(_ scenario: SidebarNestedFixture.Scenario, theme: String, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let fixture = SidebarNestedFixture(scenario: scenario)
        let width = CGFloat(fixture.width), height: CGFloat = 640
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
        let model = SidebarModel(sections: fixture.sections)
        let list = SidebarListView(model: model)
        list.frame = NSRect(x: 0, y: 0, width: width, height: height)
        root.addSubview(list)
        window.orderFrontRegardless()
        list.legacyNestedRails = fixture.legacyRails
        list.reload(animated: false)
        // The list sizes itself to its rows: pin it to the window's top (the root is not flipped).
        list.frame.origin.y = height - list.frame.height
        if let dragged = fixture.dragged, let row = list.displayed.row(for: .workspace(dragged)) {
            let frame = list.frame(for: row)
            let press = SidebarPress(key: row.key, point: NSPoint(x: frame.minX + 40, y: frame.midY))
            list.press = press
            list.beginDrag(press)
            // The drag held where the scenario names, as a pointer there holds it (the gap or a header's fill).
            list.holdNestedFixtureDrop(fixture)
            // The card under the pointer, over the drop the scenario names.
            if let lift = list.subviews.first(where: { $0 is DragLiftView }) {
                // Beside the drop, never over the label it points at: right of the names.
                lift.frame.origin.y = (list.nestedDropY(fixture) ?? frame.minY) + lift.frame.height * 0.35
                lift.frame.origin.x += 70
            }
        }
        root.layoutSubtreeIfNeeded()
        for view in Self.all(root) { view.needsDisplay = true; view.displayIfNeeded() }
        CATransaction.flush()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let image = try #require(rep.cgImage)
        list.finishDrag()
        window.close()
        return image
    }

    static func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }

    /// Runs only with `CMUX_TEST_REQUIRE_GUI` set (the fleet's opt-in for drawing tests): it writes files.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let out = Self.packageRoot.appending(path: "nested-groups-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for scenario in SidebarNestedFixture.Scenario.allCases {
            for (mode, theme, dark) in [("light", "Soft Blue Light", false), ("dark", "Soft Blue", true)] {
                let image = try Self.render(scenario, theme: theme, dark: dark)
                let url = out.appending(path: "\(scenario.rawValue)-\(mode).png")
                let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
                CGImageDestinationAddImage(dest, image, nil)
                #expect(CGImageDestinationFinalize(dest))
            }
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = Self.packageRoot
        tar.arguments = ["cf", "nested-groups-gallery.tar", "nested-groups-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
