import AppKit
@testable import CmuxNextDesign
import CmuxNextResources
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing
import CmuxNextWakeupsTestSupport

/// Frames of a sweep across tabs as AppKit draws them (user 2026-11-20, "feels jank"): the strip and its
/// hover card at each step of the pointer crossing loaded and loading GitHub tabs, on the move and once the
/// tab's picture and first sample landed, for a before/after strip of the same sweep. `CMUX_TEST_REQUIRE_GUI=1`;
/// writes `tab-hover-sweep-gallery.tar` (PNGs and `frames.txt`, each frame's card size and lines) for
/// `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AATabHoverCardSweepGalleryTests {
    /// Loaded pages have a picture and a measured renderer; the others are still loading.
    static let loaded: Set<String> = ["a", "c", "e"]

    private final class Previews: TabPreviewProvider {
        func previewImage(for tab: TabID, maxPixelSize: CGSize) async -> CGImage? {
            guard AATabHoverCardSweepGalleryTests.loaded.contains(tab.rawValue) else { return nil }
            return AATabHoverCardSweepGalleryTests.page(seed: tab.rawValue.unicodeScalars.first.map { Int($0.value) } ?? 0)
        }
    }

    /// A page-like picture: a header band and lines of "text".
    static func page(seed: Int) -> CGImage? {
        let width = 320, height = 200
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0.98, green: 0.98, blue: 0.99, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.14, green: 0.16, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: height - 28, width: width, height: 28))
        for line in 0..<9 {
            let w = 120 + (seed * 37 + line * 53) % 170
            context.setFillColor(line % 3 == 0 ? CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1)
                                                : CGColor(red: 0.55, green: 0.57, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: 16, y: height - 48 - line * 16, width: w, height: 7))
        }
        return context.makeImage()
    }

    /// The window's content and the card's window, composed at their screen places.
    static func frame(window: NSWindow, panel: HoverCardPanel?) -> CGImage? {
        func draw(_ win: NSWindow) -> (CGImage, CGRect)? {
            guard let root = win.contentView?.superview ?? win.contentView,
                  let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return nil }
            root.cacheDisplay(in: root.bounds, to: rep)
            return rep.cgImage.map { ($0, win.frame) }
        }
        guard let base = draw(window) else { return nil }
        let card = panel.flatMap { $0.isVisible ? draw($0) : nil }
        let area = CGRect(x: base.1.minX, y: base.1.maxY - 260, width: base.1.width, height: 260)
        let scale = CGFloat(base.0.width) / base.1.width
        guard let context = CGContext(data: nil, width: Int(area.width * scale), height: Int(area.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        for (image, rect) in [base] + (card.map { [$0] } ?? []) {
            let alpha = rect == base.1 ? 1 : (panel?.alphaValue ?? 1)
            context.setAlpha(alpha)
            context.draw(image, in: CGRect(x: rect.minX - area.minX, y: rect.minY - area.minY, width: rect.width, height: rect.height))
        }
        return context.makeImage()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderSweep() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let ids = ["a", "b", "c", "d", "e", "f"]
        let tabs = ids.map { id in
            var item = TabItem(id: TabID(id), title: Self.loaded.contains(id) ? "Comparing 9650ac9f5ac576bfb210d0cb72991c6e92f555d0...bd9aed0f · manaflow-ai/cmuxterm-hq" : "github.com",
                               subtitle: "https://github.com/manaflow-ai/cmuxterm-hq/compare/\(id)", icon: .symbol("globe"))
            item.hover = TabHoverFacts(kind: .browser)
            return item
        }
        let strip = TabStripView(model: TabStripModel(tabs: tabs, selectedID: TabID("a")))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 1100, height: 420), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let clock = ManualClock()
        let coordinator = HoverCardCoordinator(clock: clock)
        coordinator.appIsActive = { true }
        coordinator.hoverCardsEnabled = { true }
        coordinator.mouseButtonDown = { false }
        coordinator.windowNumberAt = { [weak window] _ in window?.windowNumber }
        coordinator.pointerLocation = { .zero }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 420))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        window.contentView = content
        strip.frame = NSRect(x: 0, y: 420 - TabStripView.preferredHeight, width: 1100, height: TabStripView.preferredHeight)
        content.addSubview(strip)
        strip.hoverCards = coordinator
        let previews = Previews()
        strip.hoverCard.previewProvider = previews
        // Held here: the strip keeps its sample source weakly.
        let source = MockResourceSource(tabs: tabs.map { item in
            TabResourceSources(tabID: item.id.rawValue, title: item.title, kind: .webkit,
                               processes: Self.loaded.contains(item.id.rawValue) ? [ProcessKey(pid: 500)] : [])
        })
        strip.hoverCard.resources.setSource(source)
        window.orderFrontRegardless()
        strip.layoutSubtreeIfNeeded()
        defer {
            coordinator.dismiss(.action)
            coordinator.panel?.closeAfterTest()
            window.contentView = nil
            window.close()
            withExtendedLifetime((source, previews)) {}
        }

        func center(_ id: String) throws -> CGPoint {
            let cell = try #require(strip.cells[TabID(id)])
            return strip.convert(CGPoint(x: cell.frame.midX, y: cell.frame.midY), from: strip.tabsClip)
        }
        func settle() async throws {
            for _ in 0..<40 { await Task.yield() }
            for _ in 0..<5 { try await Task.sleep(for: .milliseconds(10)) }
            for _ in 0..<40 { await Task.yield() }
            window.displayIfNeeded()
            coordinator.panel?.displayIfNeeded()
        }

        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "tab-hover-sweep-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var notes: [String] = []
        var index = 0
        func shoot(_ id: String, _ when: String) throws {
            window.displayIfNeeded()
            coordinator.panel?.displayIfNeeded()
            let size = coordinator.report["card_frame"].map(NSRectFromString)?.size ?? .zero
            notes.append(String(format: "%02d %@ %@: card %dx%d %@", index, id, when, Int(size.width), Int(size.height),
                                coordinator.panel?.bodyLines.description ?? "-"))
            if let image = Self.frame(window: window, panel: coordinator.panel) {
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: String(format: "%02d-%@-%@.png", index, id, when)))
            }
            index += 1
        }

        strip.updateHover(at: try center("a"), moved: true)
        try await clock.waitForSleeper()
        clock.advance(by: DesignSettings.shared.hoverCardDelay + .milliseconds(100))
        for _ in 0..<500 where coordinator.machine.shownTarget == nil { try await Task.sleep(for: .milliseconds(10)) }
        try await settle()
        try shoot("a", "settled")
        for id in ["b", "c", "d", "e", "f", "e", "d"] {
            strip.updateHover(at: try center(id), moved: true)
            try shoot(id, "move")
            try await settle()
            try shoot(id, "settled")
        }
        try notes.joined(separator: "\n").write(to: out.appending(path: "frames.txt"), atomically: true, encoding: .utf8)
        print("tab-hover-sweep-gallery\n" + notes.joined(separator: "\n"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "tab-hover-sweep-gallery.tar", "tab-hover-sweep-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
        #expect(index > 1)
    }
}
