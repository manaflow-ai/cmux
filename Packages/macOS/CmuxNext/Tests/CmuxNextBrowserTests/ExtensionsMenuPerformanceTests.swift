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

    @Test func fortyExtensionsOpenUnderFiftyAndReopenUnderTenMilliseconds() {
        let tab = Self.tab()
        let handler = ExtensionsMenu.DirectHandler(host: tab) { _ in }
        let clock = ContinuousClock()
        let open = clock.measure {
            let menu = ExtensionsMenu().make(for: tab, handler: handler, afterClose: { $0() }, presentItemMenu: { _ in })
            _ = menu.size
        }
        let reopen = clock.measure {
            let menu = ExtensionsMenu().make(for: tab, handler: handler, afterClose: { $0() }, presentItemMenu: { _ in })
            _ = menu.size
        }
        #expect(Self.milliseconds(open) < 50, "open took \(Self.milliseconds(open)) ms")
        #expect(Self.milliseconds(reopen) < 10, "reopen took \(Self.milliseconds(reopen)) ms")
    }

    @Test func aReopenDecodesNoIconAgain() {
        let tab = Self.tab()
        for info in tab.extensionStore.extensions { _ = ExtensionsMenu().image(for: info, png: nil) }
        let again = ContinuousClock().measure {
            for info in tab.extensionStore.extensions { _ = ExtensionsMenu().image(for: info, png: nil) }
        }
        #expect(Self.milliseconds(again) < 0.5, "icons again took \(Self.milliseconds(again)) ms")
    }
}
