import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxTheme
import Foundation
import Testing

/// Stills of the sidebar's top in Lawrence's msg 19185 state (a stray switch at the top left, over Home): the
/// sidebar laid out small placed the Tidy Up card, a sliver, at its top left, then took its size while the card
/// left, keeping that place for its exit. Dark and light, written under `stray-switch-gallery/` and bundled to
/// `stray-switch-gallery.tar` for `cmux-ci run --artifact`. Run once before the fix and once after it.
@MainActor @Suite(.serialized, .closesItsWindows) struct AASidebarStraySwitchGalleryTests {
    static func render(dark: Bool) async throws -> CGImage {
        let h = SidebarStraySwitchTests.Harness(width: 40, height: 120)
        defer { h.close() }
        h.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let theme = dark ? "Soft Blue" : "Soft Blue Light"
        let input = try AANestedGroupsGalleryTests.input(theme)
        _ = ThemeScope.app.store.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(theme), input: input, animated: false)
        scope.adopt(h.window)
        h.sidebar.wantsLayer = true
        h.sidebar.layer?.backgroundColor = scope.perform { Palette.sidebarBackground.withAlphaComponent(1) }.cgColor
        var on = SidebarStraySwitchTests.tidyUp
        on.id = "auto-archive.suggest.gallery"
        try await h.show(on)
        // Lawrence's switch is on: he had flipped Always.
        h.card.actionSwitch?.flip()
        h.model.noticeCard = nil
        h.sidebar.renderNow()
        h.window.setContentSize(NSSize(width: 260, height: 560))
        h.sidebar.frame.size = NSSize(width: 260, height: 560)
        h.sidebar.needsLayout = true
        h.sidebar.layoutSubtreeIfNeeded()
        h.sidebar.list.reload(animated: false)
        for view in AANestedGroupsGalleryTests.all(h.sidebar) {
            view.layoutSubtreeIfNeeded()
            view.needsDisplay = true
            view.displayIfNeeded()
        }
        CATransaction.flush()
        let top = NSRect(x: 0, y: 0, width: 260, height: 200)
        let rep = try #require(h.sidebar.bitmapImageRepForCachingDisplay(in: top))
        h.sidebar.cacheDisplay(in: top, to: rep)
        return try #require(rep.cgImage)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() async throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "stray-switch-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for dark in [true, false] {
            try AAGroupHeaderDensityGalleryTests.write(try await Self.render(dark: dark), to: out.appending(path: "top-\(dark ? "dark" : "light").png"))
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "stray-switch-gallery.tar", "stray-switch-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
