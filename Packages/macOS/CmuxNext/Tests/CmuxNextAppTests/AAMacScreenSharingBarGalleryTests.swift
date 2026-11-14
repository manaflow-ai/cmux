import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextMacScreen
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import ImageIO
import Testing

/// Three host-bar states (view only, full control, and a long viewer name), in light and dark.
@MainActor @Suite(.serialized, .closesItsWindows)
struct AAMacScreenSharingBarGalleryTests {
    private static let variants: [(name: String, title: String)] = [
        ("view-only", "Studio is viewing this Mac"),
        ("full-control", "Studio is controlling this Mac"),
        ("long-name", "Design Studio MacBook Pro with a very long name is viewing this Mac"),
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        _ = NSApplication.shared
        let out = AANestedGroupsGalleryTests.packageRoot.appending(path: "mac-screen-sharing-bar-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (mode, dark) in [("light", false), ("dark", true)] {
            for variant in Self.variants {
                let bar = MacScreenSharingBar()
                bar.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                bar.update(title: variant.title) {}
                bar.show()
                let root = try #require(bar.contentView)
                root.appearance = bar.appearance
                let theme = dark ? "Soft Blue" : "Soft Blue Light"
                let input = try AANestedGroupsGalleryTests.input(theme)
                _ = ThemeScope.app.store.apply(input)
                let scope = ThemeScope(level: .room)
                scope.setOverride(ThemeSpec(theme), input: input, animated: false)
                scope.root(root)
                root.resolveColors()
                root.layoutSubtreeIfNeeded()
                let title = try #require(findLabel(in: root, matching: variant.title))
                let stop = try #require(findButton(in: root, id: "macScreen.sharingBar.stop"))
                let titleFrame = root.convert(title.bounds, from: title)
                let stopFrame = root.convert(stop.bounds, from: stop)
                #expect(!titleFrame.intersects(stopFrame))
                let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                root.cacheDisplay(in: root.bounds, to: rep)
                let image = try #require(rep.cgImage)
                let url = out.appending(path: "\(variant.name)-\(mode).png")
                let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
                CGImageDestinationAddImage(dest, image, nil)
                #expect(CGImageDestinationFinalize(dest))
                bar.close()
            }
        }
    }

    private func findLabel(in view: NSView, matching text: String) -> NSTextField? {
        if let label = view as? NSTextField, label.stringValue == text { return label }
        for child in view.subviews {
            if let match = findLabel(in: child, matching: text) { return match }
        }
        return nil
    }

    private func findButton(in view: NSView, id: String) -> NSButton? {
        if view.accessibilityIdentifier() == id, let button = view as? NSButton { return button }
        for child in view.subviews {
            if let match = findButton(in: child, id: id) { return match }
        }
        return nil
    }
}
