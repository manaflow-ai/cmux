import AppKit
@testable import CmuxNextHome
@testable import MessagesLabSidebar
import CmuxNextTestSupport
import Testing
import UniformTypeIdentifiers

/// The before/after picture of the narrow Home list (refs/imessage-layout/2.png): the Home split
/// with the avatar-only list (76 and 120 pt) and the list with names (320 pt) beside an empty chat,
/// stacked in `.build/home-narrow-sidebar.png` (a fleet step returns it with `--artifact`). It
/// checks only that each drew; the picture is for people. `HomeNarrowSidebarTests` checks the layout.
@MainActor
@Suite(.closesItsWindows)
struct HomeNarrowSidebarCaptureTests {
    func render(listWidth: CGFloat) throws -> CGImage? {
        _ = NSApplication.shared
        let suite = "cmux.tests.narrowSidebarCapture.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 300))
        let now = Date()
        func entry(_ id: String, _ name: String, _ initials: String) -> CmuxSidebarEntry {
            CmuxSidebarEntry(id: id, title: name, people: [.init(id: "p-" + id, name: name, initials: initials)],
                             preview: "See you at the standup", previewSender: nil, lastAt: now, unreadCount: 0, pinned: false)
        }
        home.list.show([entry("a", "Mom", "M"), entry("b", "Pai-Hung", "PC"), entry("c", "Chief", "CH")], pinned: [])
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        let split = HomeSidebarSplitView(sidebar: home, content: content, widths: HomeSidebarWidth(defaults: defaults))
        split.windowKey = { "capture" }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        defer { window.close() }
        window.contentView = split
        split.wantsLayer = true
        split.layoutSubtreeIfNeeded()
        split.setWidth(listWidth)
        split.layoutSubtreeIfNeeded()
        home.list.headerView.needsLayout = true
        home.list.headerView.layoutSubtreeIfNeeded()
        CATransaction.flush()
        guard let rep = split.bitmapImageRepForCachingDisplay(in: split.bounds) else { return nil }
        split.cacheDisplay(in: split.bounds, to: rep)
        return rep.cgImage
    }

    @Test func theListAtThreeWidths() throws {
        let images = try [76, 120, 320].map { try #require(try render(listWidth: $0)) }
        let gap = 20
        let width = images.map(\.width).max() ?? 0
        let height = images.map(\.height).reduce(0, +) + gap * (images.count - 1)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { Issue.record("no context"); return }
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var y = height
        for image in images {
            y -= image.height
            ctx.draw(image, in: CGRect(x: 0, y: y, width: image.width, height: image.height))
            y -= gap
        }
        let image = try #require(ctx.makeImage())
        // The package directory: this file is Tests/CmuxNextAppTests/<name>.swift.
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = package.appendingPathComponent(".build/home-narrow-sidebar.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
