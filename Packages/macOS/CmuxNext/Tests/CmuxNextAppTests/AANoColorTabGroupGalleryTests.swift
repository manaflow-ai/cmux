import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import QuartzCore
import Testing

/// A tab group with no color in the vertical tab list, in each `tabs.vertical.noColorGroup` look (Leo 2026-11-05: "if
/// you're gonna allow the no color option, which is, like, I find kind of weird, you might as well have it be at least
/// slightly distinguishing from, like, literally depicting it as if it were unhovered"). Columns: plain (the look
/// before), pane, rimmed. Rows: dark on top, light below. The fixture: a loose tab, a blue group, an open group with no
/// color (one tab selected, one hovered), a collapsed one with no color and another loose tab. Written under
/// `no-color-tab-group-gallery/` with `all.png`, bundled to `no-color-tab-group-gallery.tar` for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AANoColorTabGroupGalleryTests {
    static let looks: [VerticalNoColorGroupLook] = [.plain, .pane, .rimmed]

    static func model() -> TabStripModel {
        let plain = TabGroupID("plain"), folded = TabGroupID("folded"), work = TabGroupID("work")
        func tab(_ id: String, _ title: String, group: TabGroupID? = nil) -> TabItem {
            TabItem(id: TabID(id), title: title, groupID: group)
        }
        return TabStripModel(tabs: [tab("a", "Inbox"), tab("w1", "Pull request", group: work), tab("w2", "CI run", group: work),
                                    tab("n1", "Search results", group: plain), tab("n2", "Selected tab", group: plain),
                                    tab("n3", "Hovered tab", group: plain), tab("f1", "hidden", group: folded), tab("b", "Docs")],
                             groups: [TabGroupItem(id: work, name: "Work", colorToken: .blue),
                                      TabGroupItem(id: plain, name: "New Group", tint: .none),
                                      TabGroupItem(id: folded, name: "Folded, no color", tint: .none, isCollapsed: true)],
                             selectedID: TabID("n2"))
    }

    static func render(_ look: VerticalNoColorGroupLook, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(TabTunables.all)
        let key = VerticalNoColorGroupLook.tunable.key
        TunableStore.shared.set(key, look.tunableValue)
        defer { TunableStore.shared.set(key, nil) }
        let width = VerticalTabListView.expandedWidth, height: CGFloat = 360
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
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
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground }.cgColor
        let model = Self.model()
        let list = VerticalTabListView(model: model)
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        list.relayout()
        list.hovered = .tab(TabID("n3"))
        for view in AANestedGroupsGalleryTests.all(root) {
            view.layoutSubtreeIfNeeded()
            view.layer?.removeAllAnimations()
            view.needsDisplay = true
            view.displayIfNeeded()
        }
        CATransaction.flush()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let image = try #require(rep.cgImage)
        window.close()
        return image
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "no-color-tab-group-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var images: [CGImage] = []
        for dark in [true, false] {
            for look in Self.looks {
                let image = try Self.render(look, dark: dark)
                images.append(image)
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(dark ? "dark" : "light")-\(look.rawValue).png"))
            }
        }
        let count = Self.looks.count
        let w = images[0].width, h = images[0].height, gap = 16
        let ctx = try #require(CGContext(data: nil, width: count * w + (count - 1) * gap, height: 2 * h + gap, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (i, image) in images.enumerated() {
            let col = i % count, row = i / count
            ctx.draw(image, in: CGRect(x: col * (w + gap), y: (1 - row) * (h + gap), width: w, height: h))
        }
        try AAGroupHeaderDensityGalleryTests.write(try #require(ctx.makeImage()), to: out.appending(path: "all.png"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "no-color-tab-group-gallery.tar", "no-color-tab-group-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
