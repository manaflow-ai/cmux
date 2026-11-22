import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSettings
import Testing
import WebKit

/// `debug.window_snapshot` renders the app's own windows without screen
/// capture: a main window by kind and by id, a standalone window by kind,
/// with the traffic lights in the picture.
@MainActor
@Suite(.serialized)
struct DebugWindowSnapshotTests {
    private func path(_ name: String) -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("snapshot-test-\(UUID().uuidString)-\(name).png")
    }

    @Test func aMainWindowRendersAtItsBackingSize() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        services.daemon.store.apply(snapshot: try BrowserTabTests.tree())
        let workspace = try #require(services.daemon.store.workspaces.first)
        let main = try #require(services.windows.openWindow(workspaces: [workspace.id]))
        services.windows.didActivate(main)
        let window = try #require(main.window)
        for params: [String: JSONValue] in [["kind": .string("main")], ["window": .string(main.state.id)]] {
            let output = path("main")
            let result = DebugWindowSnapshot.capture(params.merging(["path": .string(output)]) { $1 }, services: services)
            #expect(result["error"] == nil, "\(result)")
            #expect(result["kind"]?.stringValue == "main")
            let scale = window.backingScaleFactor
            #expect(result["width"]?.intValue == Int((window.frame.width * scale).rounded()), "\(result)")
            let image = try #require(NSImage(contentsOfFile: output))
            #expect(image.size.width > 0)
            try? FileManager.default.removeItem(atPath: output)
        }
    }

    /// The prewarmed new tab page waits in `NewTabSpareParking`, which is
    /// fully transparent so WebKit keeps rendering it out of sight. It is not
    /// on screen, so the snapshot must not paint it over the window (it hid
    /// the sidebar and the tabs); a web view in a visible pane is painted.
    @Test func aParkedSpareIsNotPaintedOverTheWindow() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = content
        let parking = NewTabSpareParking(frame: content.bounds)
        content.addSubview(parking, positioned: .below, relativeTo: nil)
        let spare = WKWebView(frame: parking.bounds)
        parking.addSubview(spare)
        let pane = NSView(frame: NSRect(x: 100, y: 0, width: 300, height: 300))
        content.addSubview(pane)
        let page = WKWebView(frame: pane.bounds)
        pane.addSubview(page)
        #expect(spare.window === window, "the spare is in the window, as the pool parks it")
        let painted = DebugWindowSnapshot.visibleWebViews(in: window).map(ObjectIdentifier.init)
        #expect(painted == [ObjectIdentifier(page)], "painted \(painted.count) web views; the parked spare must not be one")
    }

    @Test(.requiresGUISession) func aStandaloneWindowRendersItsTrafficLights() throws {
        let services = ActionBindingCoverageTests.boundServices()
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 320, height: 200),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("cmux.snapshotProbe")
        window.isReleasedWhenClosed = false
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1).cgColor
        window.contentView = content
        window.orderBack(nil)
        defer { window.close() }
        let output = path("probe")
        let result = DebugWindowSnapshot.capture(["kind": .string("snapshotProbe"), "path": .string(output)], services: services)
        #expect(result["kind"]?.stringValue == "snapshotProbe", "\(result)")
        let rep = try #require(window.renderSnapshot())
        // The content is green; the titlebar's close button is not.
        let middle = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB)
        #expect((middle?.greenComponent ?? 0) > (middle?.redComponent ?? 1) + 0.3, "\(String(describing: middle))")
        let button = try #require(window.standardWindowButton(.closeButton))
        let frameView = try #require(window.contentView?.superview)
        let rect = button.convert(button.bounds, to: frameView)
        let scale = window.backingScaleFactor
        let x = Int(rect.midX * scale)
        let y = rep.pixelsHigh - Int(rect.midY * scale)
        let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
        #expect(pixel != nil)
        try? FileManager.default.removeItem(atPath: output)
    }
}
