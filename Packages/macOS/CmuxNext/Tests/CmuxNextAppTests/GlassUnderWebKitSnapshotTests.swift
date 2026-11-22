import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import Foundation
import Testing
import WebKit

/// cx-ddjj: with a WebKit page on screen (Settings), `debug.window_snapshot`
/// drew the window through AppKit (`cacheDisplay`), and a column holding a
/// Liquid Glass card (the sidebar with its "Did you know" card) came out
/// fully transparent: no rows, no background, while the screen showed both.
/// The snapshot must show what the screen shows: with window server images
/// it takes the window server's image, and the column's views are in it.
@MainActor
@Suite(.serialized)
struct GlassUnderWebKitSnapshotTests {
    private struct Fixture {
        let window: NSWindow
        func close() { window.close() }
    }

    /// A gray window: a WebKit page on the right half, and on the left a
    /// column with a solid green row and a glass card below it.
    private func fixture() -> Fixture {
        _ = NSApplication.shared
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(contentRect: NSRect(x: screen.minX + 40, y: screen.minY + 40, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1).cgColor
        content.addSubview(WKWebView(frame: NSRect(x: 200, y: 0, width: 200, height: 300)))
        let column = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        column.wantsLayer = true
        let row = NSView(frame: NSRect(x: 20, y: 200, width: 160, height: 60))
        row.wantsLayer = true
        row.layer?.backgroundColor = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1).cgColor
        column.addSubview(row)
        let card = OverlaySurfaceView(material: .liquidGlass, interactive: true, cornerRadius: 12)
        card.frame = NSRect(x: 20, y: 20, width: 160, height: 80)
        column.addSubview(card)
        content.addSubview(column)
        window.contentView = content
        window.orderFrontRegardless()
        window.displayIfNeeded()
        // The window server draws a new window on a later display cycle.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, window.compositedSnapshot() == nil {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return Fixture(window: window)
    }

    private func path() -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("glass-webkit-snapshot-\(UUID().uuidString).png")
    }

    @Test(.requiresGUISession, .requiresWindowServerImages) func aGlassColumnBesideAWebKitPageShowsItsRows() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        let fixture = fixture()
        defer { fixture.close() }
        let result = await DebugWindowSnapshot.captureAsync(["window": .string(String(fixture.window.windowNumber)), "path": .string(path())],
                                                            services: services)
        #expect(result["webviews"]?.intValue == 1, "\(result)")
        #expect(result["method"]?.stringValue == "composited", "the screen's image is available, so the snapshot uses it: \(result)")
        let output = try #require(result["path"]?.stringValue, "\(result)")
        defer { try? FileManager.default.removeItem(atPath: output) }
        let rep = try #require(FileManager.default.contents(atPath: output).flatMap(NSBitmapImageRep.init(data:)))
        let scale = CGFloat(rep.pixelsWide) / fixture.window.frame.width
        // The green row's center: 100, 70 from the window's top left.
        let pixel = try #require(rep.colorAt(x: Int(100 * scale), y: Int(70 * scale))?.usingColorSpace(.sRGB))
        // Green in the display's color space (the window server image is not sRGB-exact).
        #expect(pixel.alphaComponent > 0.9 && pixel.greenComponent > 0.8 && pixel.greenComponent > pixel.redComponent + 0.3,
                "the row beside the glass card is missing from the snapshot: \(pixel)")
    }
}
