import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// Shots of the Tab Bar Playground's crowded agent rows (Leo, 2026-11-27: "ok why dont your tabs have any
/// names/letters showing up? that intentional?"): the real strip at 26 tabs, a spinner and a machine badge on every
/// other tab, for each agent variant in ``CrowdedTabsPlaygroundVariants``, dark and light, written as
/// `NN-<appearance>.png` with `variants.tsv` naming each. `CMUX_TEST_REQUIRE_GUI=1`; bundled to
/// `crowded-agent-tabs-gallery.tar` for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AACrowdedAgentTabsGalleryTests {
    static let width: CGFloat = 900, height: CGFloat = 44, tabCount = 26

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        _ = NSApplication.shared
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "crowded-agent-tabs-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let variants = CrowdedTabsPlaygroundVariants().all.filter { $0.name.hasPrefix("Agent tabs") }
        #expect(variants.count == 4)
        var names = ["index\tvariant"]
        for (index, variant) in variants.enumerated() { names.append(String(format: "%02d", index) + "\t" + variant.name) }
        for dark in [true, false] {
            for (index, variant) in variants.enumerated() {
                let image = try Self.render(variant, dark: dark)
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: String(format: "%02d-%@.png", index,
                                                                                                dark ? "dark" : "light")))
            }
        }
        try (names.joined(separator: "\n") + "\n").write(to: out.appending(path: "variants.tsv"), atomically: true, encoding: .utf8)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "crowded-agent-tabs-gallery.tar", "crowded-agent-tabs-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }

    static func render(_ variant: TabBarPlaygroundVariant, dark: Bool) throws -> CGImage {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        let theme = dark ? "Soft Blue" : "Soft Blue Light"
        let input = try AANestedGroupsGalleryTests.input(theme)
        _ = ThemeScope.app.store.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(theme), input: input, animated: false)
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.surfaceBackground.withAlphaComponent(1) }.cgColor
        let bar = variant.make(tabCount)
        bar.frame = root.bounds
        bar.autoresizingMask = [.width, .height]
        root.addSubview(bar)
        window.orderFrontRegardless()
        for _ in 0..<3 {
            for view in AANestedGroupsGalleryTests.all(root) {
                view.needsLayout = true
            }
            root.layoutSubtreeIfNeeded()
        }
        for view in AANestedGroupsGalleryTests.all(root) {
            view.layer?.removeAllAnimations()
            view.needsDisplay = true
            view.displayIfNeeded()
        }
        CATransaction.flush()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        return try #require(rep.cgImage)
    }
}
