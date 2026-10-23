import AppKit
@testable import MessagesLabSidebar
import Testing
import UniformTypeIdentifiers

/// The picture of the pinned grid with unread tiles in dark and light (the user, 2026-10-21:
/// pinned unread is a blue dot inline before the name, as Messages, and nothing intersects): the
/// list at 320 pt (3 columns) and 240 pt (2 columns) with short and long names and previews,
/// stacked dark over light in `.build/pinned-unread-dot.png` (a fleet step returns it with
/// `--artifact`). It checks only that each drew; `PinnedUnreadDotLayoutTests` checks the layout.
@MainActor
@Suite(.serialized)
struct PinnedUnreadDotCaptureTests {
    private func render(width: CGFloat, dark: Bool) throws -> CGImage? {
        _ = NSApplication.shared
        let height: CGFloat = 330
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { window.close() }
        let backdrop = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.96, alpha: 1)).cgColor
        window.contentView = backdrop
        let view = CmuxSidebarView(frame: backdrop.bounds)
        backdrop.addSubview(view)
        view.unreadColor = .systemBlue
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func entry(_ id: String, _ name: String, _ initials: String, unread: Int, preview: String, ago: Double) -> CmuxSidebarEntry {
            CmuxSidebarEntry(id: id, title: name, people: [.init(id: "p-" + id, name: name, initials: initials)],
                             preview: preview, previewSender: nil, lastAt: now.addingTimeInterval(-ago), unreadCount: unread, pinned: true)
        }
        let entries = [
            entry("a", "Chief", "CH", unread: 2, preview: "I can't open your two screenshots, can you send them again?", ago: 60),
            entry("b", "Instinct", "IN", unread: 1, preview: "Sent one to your phone-number thread", ago: 120),
            entry("c", "Austin", "A", unread: 0, preview: "See you at the standup", ago: 600),
            entry("d", "Maximilian-Alexander", "MA", unread: 1, preview: "ok", ago: 900),
            entry("e", "Al", "AL", unread: 1, preview: "Landed the fix, can you look?", ago: 1200),
        ]
        view.show(entries, pinned: entries.map(\.id))
        backdrop.layoutSubtreeIfNeeded()
        view.controller.view.layoutSubtreeIfNeeded()
        view.controller.document.layoutSubtreeIfNeeded()
        view.controller.tile(force: true)
        CATransaction.flush()
        guard let rep = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds) else { return nil }
        backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
        return rep.cgImage
    }

    @Test func pinnedUnreadInDarkAndLight() throws {
        let gap = 20
        // Rows: dark, light; columns: 320 pt, 240 pt.
        let grid = try [true, false].map { dark in try [320, 240].map { try #require(try render(width: $0, dark: dark)) } }
        let width = grid.map { $0.map(\.width).reduce(0, +) + gap * ($0.count - 1) }.max() ?? 0
        let height = grid.map { $0.map(\.height).max() ?? 0 }.reduce(0, +) + gap * (grid.count - 1)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
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
        // The package directory: this file is Tests/MessagesLabSidebarTests/<name>.swift.
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = package.appendingPathComponent(".build/pinned-unread-dot.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
