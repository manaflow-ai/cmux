import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextHome
import CmuxNextTestSupport
import CmuxTheme
@testable import MessagesLabSidebar
import Testing
import UniformTypeIdentifiers

/// The before/after picture of the Home list's unread dots in dark and light (the user,
/// 2026-10-21: "we need to add blue unread dots to home"): the list with names (320 pt) and the
/// avatar-only list (76 pt) over the default neutral theme, before (the theme accent, a grey) and
/// after (the notification blue), stacked in `.build/home-unread-dots.png` (a fleet step returns
/// it with `--artifact`). It checks only that each drew; `HomeSidebarUnreadDotTests` checks the dot.
@MainActor
@Suite(.closesItsWindows)
struct HomeUnreadDotCaptureTests {
    private func render(width: CGFloat, dark: Bool, before: Bool) throws -> CGImage? {
        _ = NSApplication.shared
        let input = dark
            ? ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xFFFFFF))
            : ThemeInput(background: ThemeRGB(hex: 0xF5F5F5), foreground: ThemeRGB(hex: 0x1E1E1E))
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec("Neutral"), input: input, animated: false)
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: width, height: 330))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 330), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { window.close() }
        let backdrop = NSView(frame: window.contentLayoutRect)
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.96, alpha: 1)).cgColor
        window.contentView = backdrop
        home.frame = backdrop.bounds
        backdrop.addSubview(home)
        scope.root(home)
        home.list.controller.appearanceChanged()
        home.applyColors()
        // Before: the dot in the theme accent, as the list drew it before this change.
        if before { home.unreadDotColor = home.performWithTheme { Palette.accent } }
        let now = Date()
        func entry(_ id: String, _ name: String, _ initials: String, unread: Int, pinned: Bool = false, ago: Double) -> CmuxSidebarEntry {
            CmuxSidebarEntry(id: id, title: name, people: [.init(id: "p-" + id, name: name, initials: initials)],
                             preview: unread > 0 ? "Landed the fix, can you look?" : "See you at the standup", previewSender: nil,
                             lastAt: now.addingTimeInterval(-ago), unreadCount: unread, pinned: pinned)
        }
        home.list.show([entry("a", "Chief", "CH", unread: 2, pinned: true, ago: 60), entry("b", "Austin", "A", unread: 0, pinned: true, ago: 600),
                        entry("c", "Mia", "M", unread: 1, ago: 120), entry("d", "Pai-Hung", "PC", unread: 0, ago: 3600),
                        entry("e", "Leo", "L", unread: 4, ago: 7200)], pinned: ["a", "b"])
        backdrop.layoutSubtreeIfNeeded()
        home.list.headerView.needsLayout = true
        home.list.headerView.layoutSubtreeIfNeeded()
        CATransaction.flush()
        guard let rep = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds) else { return nil }
        backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
        return rep.cgImage
    }

    @Test func beforeAndAfterInDarkAndLight() throws {
        let gap = 20
        // Rows: dark before, dark after, light before, light after; columns: 320 pt, 76 pt.
        var grid: [[CGImage]] = []
        for dark in [true, false] {
            for before in [true, false] {
                grid.append(try [320, 76].map { try #require(try render(width: $0, dark: dark, before: before)) })
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
        // The package directory: this file is Tests/CmuxNextAppTests/<name>.swift.
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = package.appendingPathComponent(".build/home-unread-dots.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
