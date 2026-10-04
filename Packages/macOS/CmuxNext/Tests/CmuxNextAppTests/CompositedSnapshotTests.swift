import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// `debug.window_snapshot` captures the composited window (vibrancy and
/// glass as on screen) when the window server gives the app its own
/// window's image, and AppKit drawing otherwise; it says which in `method`.
/// A test process without a window server session (or a window off every
/// screen) only gets `appkit`; then the composited assertions are skipped
/// and the tagged-app proof on the host covers them.
@MainActor
@Suite(.serialized)
struct CompositedSnapshotTests {
    @Test func aGlassAreaAndAPopoverRenderNonBlank() throws {
        _ = NSApplication.shared
        let services = ActionBindingCoverageTests.boundServices()
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-composited-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(contentRect: NSRect(x: screen.minX + 20, y: screen.minY + 20, width: 360, height: 240),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView()
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 160, height: 240))
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .active
        content.addSubview(effect)
        window.install(kind: .settings, content: content, scope: .app)
        window.orderFrontRegardless()
        defer { window.close() }
        window.displayIfNeeded()

        let path = directory.appending(path: "window.png").path
        let result = DebugWindowSnapshot.capture(["window": .string(String(window.windowNumber)), "path": .string(path)], services: services)
        let method = try #require(result["method"]?.stringValue, "\(result)")
        #expect(["composited", "appkit"].contains(method))
        let data = try #require(FileManager.default.contents(atPath: path))
        let rep = try #require(NSBitmapImageRep(data: data))
        #expect(rep.pixelsWide > 0 && rep.pixelsHigh > 0)
        if method == "composited" {
            // A pixel inside the glass area (left column, mid height) is drawn.
            let scale = CGFloat(rep.pixelsWide) / window.frame.width
            let pixel = rep.colorAt(x: Int(40 * scale), y: Int(120 * scale))
            #expect((pixel?.alphaComponent ?? 0) > 0.5, "glass area blank in the composited image: \(String(describing: pixel))")
        }

        let anchor = NSView(frame: NSRect(x: 200, y: 100, width: 20, height: 20))
        window.installedContent?.addSubview(anchor)
        let popover = NSPopover()
        let popoverContent = NSViewController()
        popoverContent.view = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 90))
        popover.contentViewController = popoverContent
        popover.animates = false
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        defer { popover.close() }
        let popoverWindow = try #require(popoverContent.view.window)
        let popoverPath = directory.appending(path: "popover.png").path
        let popoverResult = DebugWindowSnapshot.capture(["window": .string(String(popoverWindow.windowNumber)), "path": .string(popoverPath)],
                                                        services: services)
        #expect(popoverResult["kind"]?.stringValue == "popover")
        #expect(popoverResult["method"]?.stringValue != nil)
        let popoverRep = try #require(FileManager.default.contents(atPath: popoverPath).flatMap(NSBitmapImageRep.init(data:)))
        #expect(popoverRep.pixelsWide > 0 && popoverRep.pixelsHigh > 0)
    }
}
