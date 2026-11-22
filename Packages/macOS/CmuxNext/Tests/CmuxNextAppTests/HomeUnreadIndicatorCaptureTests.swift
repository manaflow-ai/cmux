import AppKit
@testable import CmuxNextApp
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing
import UniformTypeIdentifiers

/// The before/after picture of Home's unread outside Home (the user, 2026-10-21: "we need to show
/// unread indicator in home too"): the sidebar's Home item in the built-in, list and tile looks and a
/// tab strip holding a Home tab, with three Home conversations unread, before (no count, no dot) and
/// after, in dark then light, stacked in `.build/home-unread-indicator.png` (a fleet step returns it
/// with `--artifact`). It checks only that each drew; `HomeUnreadIndicatorTests` checks the rule.
@MainActor
@Suite(.closesItsWindows)
struct HomeUnreadIndicatorCaptureTests {
    private func snapshot(_ view: NSView, size: NSSize, dark: Bool) -> CGImage? {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { window.close() }
        let backdrop = NSView(frame: NSRect(origin: .zero, size: size))
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.96, alpha: 1)).cgColor
        window.contentView = backdrop
        view.frame = backdrop.bounds.insetBy(dx: 8, dy: 6)
        backdrop.addSubview(view)
        backdrop.layoutSubtreeIfNeeded()
        CATransaction.flush()
        guard let rep = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds) else { return nil }
        backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
        return rep.cgImage
    }

    private func homeItem(style: SidebarItemRowView.Style, after: Bool, dark: Bool) -> CGImage? {
        let item = LayoutItem(id: LayoutItemID("itm_home"), ref: .app("cmux/home"))
        let layout = SidebarLayoutDocument(sections: [LayoutSection(id: LayoutSectionID("sec_top"), region: .top, items: [item])])
        let info = SidebarBridge.itemInfo(for: layout, registered: { _ in true }, homeUnread: after ? 3 : 0)[item.id]
            ?? SidebarItemInfo.fallback(for: item.ref)
        let row = SidebarItemRowView(frame: .zero)
        row.configure(info, style: style)
        let size = style.isIconOnly ? NSSize(width: 56, height: 52) : NSSize(width: 240, height: 40)
        return snapshot(row, size: size, dark: dark)
    }

    private func strip(after: Bool, dark: Bool) -> CGImage? {
        var home = TabItem(id: TabID("home"), title: "Home", icon: .symbol("house"))
        home.isUnread = after
        let model = TabStripModel(tabs: [TabItem(id: TabID("term"), title: "zsh"), home], selectedID: TabID("term"))
        let strip = TabStripView(model: model)
        strip.dragsWindowFromEmptySpace = false
        return snapshot(strip, size: NSSize(width: 420, height: TabStripView.preferredHeight + 12), dark: dark)
    }

    @Test func beforeAndAfterInDarkAndLight() throws {
        let gap = 16
        var grid: [[CGImage]] = []
        for dark in [true, false] {
            for after in [false, true] {
                let items = [SidebarItemRowView.Style.builtIn, .list, .tile].compactMap { homeItem(style: $0, after: after, dark: dark) }
                grid.append(items + [try #require(strip(after: after, dark: dark))])
            }
        }
        let width = grid.map { $0.map(\.width).reduce(0, +) + gap * ($0.count - 1) }.max() ?? 0
        let height = grid.map { $0.map(\.height).max() ?? 0 }.reduce(0, +) + gap * (grid.count - 1)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { Issue.record("no context"); return }
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var y = height
        for row in grid {
            let rowHeight = row.map(\.height).max() ?? 0
            y -= rowHeight
            var x = 0
            for image in row {
                ctx.draw(image, in: CGRect(x: x, y: y + rowHeight - image.height, width: image.width, height: image.height))
                x += image.width + gap
            }
            y -= gap
        }
        let image = try #require(ctx.makeImage())
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = package.appendingPathComponent(".build/home-unread-indicator.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
