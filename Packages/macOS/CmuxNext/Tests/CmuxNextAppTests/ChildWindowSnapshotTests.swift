import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing
import WebKit

/// Chromium draws a page into a child window of the main window, so
/// `debug.window_snapshot` must composite the window's visible child windows
/// over it, or every Chromium page is blank in a proof. A solid red child
/// window over a gray window stands in for the page: the pixel at the
/// child's center must be red in both snapshot paths (the window server
/// image alone, and the AppKit base drawn under painted WebKit pages).
@MainActor
@Suite(.serialized)
struct ChildWindowSnapshotTests {
    private struct Fixture {
        let window: NSWindow
        let child: NSWindow
        func close() {
            window.removeChildWindow(child)
            child.close()
            window.close()
        }
    }

    private func fixture(webView: Bool) -> Fixture {
        _ = NSApplication.shared
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(contentRect: NSRect(x: screen.minX + 40, y: screen.minY + 40, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1).cgColor
        if webView {
            // A WebKit page in the left quarter: the snapshot takes its
            // AppKit-drawn base path and paints the page over it.
            content.addSubview(WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 300)))
        }
        window.contentView = content
        window.orderFrontRegardless()
        // The page window: a borderless child over the window's center.
        let child = NSWindow(contentRect: NSRect(x: window.frame.minX + 150, y: window.frame.minY + 100, width: 100, height: 100),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        child.isReleasedWhenClosed = false
        child.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        child.isOpaque = true
        window.addChildWindow(child, ordered: .above)
        child.orderFrontRegardless()
        window.displayIfNeeded()
        child.displayIfNeeded()
        // The window server draws a new window on a later display cycle;
        // until then its image is blank. Give both windows up to 3 s.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, window.compositedSnapshot(includeChild: { _ in false }) == nil
            || child.compositedSnapshot() == nil {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return Fixture(window: window, child: child)
    }

    /// The pixel at the child window's center in the snapshot `result` wrote.
    private func centerPixel(_ result: JSONValue, window: NSWindow) throws -> NSColor {
        let path = try #require(result["path"]?.stringValue, "\(result)")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let rep = try #require(FileManager.default.contents(atPath: path).flatMap(NSBitmapImageRep.init(data:)))
        let scale = CGFloat(rep.pixelsWide) / window.frame.width
        // 200, 150 from the window's top left is the child's center.
        return try #require(rep.colorAt(x: Int(200 * scale), y: Int(150 * scale))?.usingColorSpace(.sRGB))
    }

    private func isRed(_ color: NSColor) -> Bool {
        color.redComponent > 0.8 && color.greenComponent < 0.3 && color.blueComponent < 0.3
    }

    private func path() -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("child-snapshot-\(UUID().uuidString).png")
    }

    @Test(.requiresGUISession) func theWindowServerImageIncludesAChildWindow() throws {
        let services = ActionBindingCoverageTests.boundServices()
        let fixture = fixture(webView: false)
        defer { fixture.close() }
        let result = DebugWindowSnapshot.capture(["window": .string(String(fixture.window.windowNumber)), "path": .string(path())],
                                                 services: services)
        #expect(result["method"]?.stringValue == "composited", "\(result)")
        let pixel = try centerPixel(result, window: fixture.window)
        #expect(isRed(pixel), "the child window is missing from the snapshot: \(pixel)")
        #expect(result["child_windows"]?.intValue == 1, "\(result)")
    }

    @Test(.requiresGUISession) func theAppKitBaseUnderWebKitPagesIncludesAChildWindow() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        let fixture = fixture(webView: true)
        defer { fixture.close() }
        let result = await DebugWindowSnapshot.captureAsync(["window": .string(String(fixture.window.windowNumber)), "path": .string(path())],
                                                            services: services)
        #expect(result["webviews"]?.intValue == 1, "\(result)")
        let pixel = try centerPixel(result, window: fixture.window)
        #expect(isRed(pixel), "the child window is missing from the snapshot: \(pixel)")
        #expect(result["child_windows"]?.intValue == 1, "\(result)")
    }
}
