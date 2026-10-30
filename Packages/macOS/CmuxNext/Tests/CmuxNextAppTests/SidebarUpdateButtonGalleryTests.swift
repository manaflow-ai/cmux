import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxTheme
import Foundation
import Testing

/// The sidebar with a found update waiting (the quiet Update Available button), the Priority bell on and the
/// titlebar revealed, dark and light (Leo 2026-10-28: "the update button, don't put at the top. Put on the bottom").
/// Artifact `sidebar-update-button-gallery.tar` (`CMUX_TEST_REQUIRE_GUI=1`).
@MainActor @Suite(.serialized) struct SidebarUpdateButtonGalleryTests {
    static func render(dark: Bool) throws -> CGImage {
        let (_, sidebar, window) = SidebarTabGroupControlsTests.sidebar()
        defer { window.close() }
        let theme = dark ? "Soft Blue" : "Soft Blue Light"
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = NSView(frame: sidebar.frame)
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        root.addSubview(sidebar)
        let input = try AANestedGroupsGalleryTests.input(theme)
        _ = ThemeScope.app.store.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(theme), input: input, animated: false)
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor
        window.orderFrontRegardless()
        sidebar.showPriority(SidebarPriorityPanel(entries: [], shown: false))
        sidebar.showUpdateAvailable("Update Available")
        sidebar.renderNow()
        // The titlebar row as the pointer reveals it: the + shows beside the bell.
        sidebar.newButton.alphaValue = 1
        for view in AANestedGroupsGalleryTests.all(root) { view.layoutSubtreeIfNeeded(); view.needsDisplay = true; view.displayIfNeeded() }
        CATransaction.flush()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        return try #require(rep.cgImage)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderTheUpdateButton() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "sidebar-update-button-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for dark in [true, false] {
            try AAGroupHeaderDensityGalleryTests.write(try Self.render(dark: dark), to: out.appending(path: dark ? "dark.png" : "light.png"))
        }
        let tar = Process(); tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar"); tar.currentDirectoryURL = root
        tar.arguments = ["cf", "sidebar-update-button-gallery.tar", "sidebar-update-button-gallery"]
        try tar.run(); tar.waitUntilExit(); #expect(tar.terminationStatus == 0)
    }
}
