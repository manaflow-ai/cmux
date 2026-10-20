import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// The Extensions menu opens and hovers within a frame budget (u2229: "this extensions context
/// menu is also extremely laggy"). Budgets: an open under 50 ms, a second open under 10 ms, a
/// hover under 16 ms, with 40 extensions.
@MainActor @Suite(.serialized) struct ExtensionsMenuPerformanceTests {
    static let count = 40

    static func iconFile(_ index: Int, in directory: URL) -> String {
        let size = 128
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(hue: CGFloat(index % 10) / 10, saturation: 0.7, brightness: 0.8, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 4, y: 4, width: 120, height: 120)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let url = directory.appendingPathComponent("icon-\(index).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        return url.path
    }

    static func tab(extensions count: Int = count) -> MockBrowserTab {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ext-menu-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com")))
        tab.showsExtensionToolbar = true
        tab.extensionBackend.extensions = (0..<count).map { index in
            BrowserExtensionInfo(id: "ext\(index)", name: "Extension \(index)", location: .webstore, hasAction: true,
                                 isPinned: index % 3 == 0, optionsURL: URL(string: "chrome-extension://ext\(index)/options.html"),
                                 iconPath: iconFile(index, in: directory))
        }
        tab.extensionStore.refresh()
        return tab
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    /// A visible window with the Extensions button at its top right.
    static func window() -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = NSView(frame: NSRect(x: 860, y: 660, width: 28, height: 28))
        window.contentView?.addSubview(anchor)
        window.orderFrontRegardless()
        return (window, anchor)
    }

    @Test func fortyExtensionsOpenUnderFiftyAndReopenUnderTenMilliseconds() throws {
        let tab = Self.tab()
        let (window, anchor) = Self.window()
        defer { window.close() }
        let handler = ExtensionsMenu.DirectHandler(host: tab) { _ in }
        let controller = ExtensionsMenuController()
        let clock = ContinuousClock()
        let open = clock.measure { controller.show(host: tab, handler: handler, anchor: anchor) }
        try #require(controller.isShown)
        #expect(controller.content.rows.count == Self.count)
        controller.close()
        let reopen = clock.measure { controller.show(host: tab, handler: handler, anchor: anchor) }
        #expect(controller.isShown)
        print("TOOLBAR-PERF extensions.open=\(Self.milliseconds(open)) ms extensions.reopen=\(Self.milliseconds(reopen)) ms")
        #expect(Self.milliseconds(open) < 50, "open took \(Self.milliseconds(open)) ms")
        #expect(Self.milliseconds(reopen) < 10, "reopen took \(Self.milliseconds(reopen)) ms")
        controller.close()
    }

    @Test func aReopenDecodesNoIconAgain() throws {
        let tab = Self.tab()
        let (window, anchor) = Self.window()
        defer { window.close() }
        let handler = ExtensionsMenu.DirectHandler(host: tab) { _ in }
        let controller = ExtensionsMenuController()
        controller.show(host: tab, handler: handler, anchor: anchor)
        try #require(controller.isShown)
        #expect(controller.icons.loads == Self.count)
        controller.close()
        controller.show(host: tab, handler: handler, anchor: anchor)
        #expect(controller.icons.loads == Self.count, "a reopen read icon files again")
        controller.close()
    }

    @Test func hoveringARowRedrawsWithinAFrame() throws {
        let tab = Self.tab()
        let (window, anchor) = Self.window()
        defer { window.close() }
        let controller = ExtensionsMenuController()
        controller.show(host: tab, handler: ExtensionsMenu.DirectHandler(host: tab) { _ in }, anchor: anchor)
        try #require(controller.isShown)
        let enter = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                        windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        let exit = try #require(NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                                                       windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        let clock = ContinuousClock()
        var slowest = Duration.zero
        for row in controller.content.rows {
            let rep = try #require(row.bitmapImageRepForCachingDisplay(in: row.bounds))
            let hover = clock.measure {
                row.primary.mouseEntered(with: enter)
                row.cacheDisplay(in: row.bounds, to: rep)
                row.primary.mouseExited(with: exit)
            }
            slowest = max(slowest, hover)
        }
        print("TOOLBAR-PERF extensions.hover.max=\(Self.milliseconds(slowest)) ms")
        #expect(Self.milliseconds(slowest) < 16, "slowest hover took \(Self.milliseconds(slowest)) ms")
        controller.close()
    }

    @Test func openingDoesNotWaitForChromium() throws {
        let tab = Self.tab()
        let (window, anchor) = Self.window()
        defer { window.close() }
        let before = tab.extensionBackend.snapshots
        let controller = ExtensionsMenuController()
        controller.show(host: tab, handler: ExtensionsMenu.DirectHandler(host: tab) { _ in }, anchor: anchor)
        try #require(controller.isShown)
        #expect(tab.extensionBackend.snapshots == before, "the open asked Chromium for the list before it showed")
        #expect(controller.renders == 1)
        controller.close()
    }
}
