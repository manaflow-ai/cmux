import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// Crops for Aziz 2026-11-09 ("The horizontal tab width shrinks when I pin and it lacks a pin indicator"): a
/// four-tab strip before any pin, after pinning its second tab (default settings), and after pinning with the
/// icon-only form (`tabs.pinnedKeepsTitle` off), dark and light. Written under `pinned-tab-width-gallery/` with
/// `all.png` (dark on top, light below), bundled to `pinned-tab-width-gallery.tar` for `cmux-ci run --artifact`.
/// It uses only APIs the base has (the tunable by its key, which the base's store refuses), so a run at the base
/// and one at the head compare.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAPinnedTabWidthGalleryTests {
    static let names = ["unpinned", "pinned", "pinned-icon-only"]
    static let key = "tabs.pinnedKeepsTitle"

    /// The strip of one state; `pin`: pin the second tab; `keepsTitle`: the tunable's value, nil for its default.
    static func crop(dark: Bool, pin: Bool, keepsTitle: Bool?) throws -> CGImage {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(TabTunables.all)
        _ = TunableStore.shared.set(key, keepsTitle.map(TunableValue.bool))
        defer { _ = TunableStore.shared.set(key, nil) }
        DesignSettings.shared.tabOverflow = .shrink
        let titles = ["Computer Use via cua-driver", "V3", "feat-cmux-next", "Chief"]
        let icons = ["terminal", "globe", "terminal", "sparkles"]
        let tabs = titles.indices.map { TabItem(id: TabID("tab\($0)"), title: titles[$0], icon: .symbol(icons[$0])) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        let model = TabStripModel(tabs: tabs, selectedID: tabs[2].id)
        let strip = TabStripView(model: model)
        strip.dragsWindowFromEmptySpace = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: TabStripView.preferredHeight))
        strip.frame = root.bounds
        root.addSubview(strip)
        window.contentView = root
        try AAPinnedNoCloseGalleryTests.theme(root, window, dark: dark)
        strip.applyTokens(animated: false)
        if pin { _ = model.apply(.pin(tabs[0].id)) { TabItem(id: TabID("unused"), title: "") } }
        strip.sync(fromModel: true, animating: false)
        strip.layoutSubtreeIfNeeded()
        strip.layoutSubtreeIfNeeded()
        return try AAPinnedNoCloseGalleryTests.crop(root, root.bounds.insetBy(dx: 6, dy: 6))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "pinned-tab-width-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var images: [CGImage] = []
        for dark in [true, false] {
            for (name, state) in zip(Self.names, [(false, Bool?.none), (true, nil), (true, false)]) {
                let image = try Self.crop(dark: dark, pin: state.0, keepsTitle: state.1)
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
                images.append(image)
            }
        }
        // The six strips stacked: dark (unpinned, pinned, icon-only), then light.
        let gap = 12
        let w = images.map(\.width).max() ?? 1, h = images.map(\.height).max() ?? 1
        let ctx = try #require(CGContext(data: nil, width: w + 2 * gap, height: images.count * (h + gap) + gap,
                                         bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (index, image) in images.enumerated() {
            let y = ctx.height - (index + 1) * (h + gap)
            ctx.draw(image, in: CGRect(x: gap, y: y, width: image.width, height: image.height))
        }
        try AAGroupHeaderDensityGalleryTests.write(try #require(ctx.makeImage()), to: out.appending(path: "all.png"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "pinned-tab-width-gallery.tar", "pinned-tab-width-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
