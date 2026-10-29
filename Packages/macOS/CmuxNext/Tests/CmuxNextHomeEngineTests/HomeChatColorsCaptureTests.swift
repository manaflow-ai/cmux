import AppKit
import CmuxNextDesign
@testable import CmuxNextHome
import Foundation
import Testing

/// Throwaway: draws the Chat Colors… panel's content in light and dark, side by side, into
/// chatcolors-capture.png at the repository root (a before/after capture; never merged).
@MainActor @Suite struct HomeChatColorsCaptureTests {
    @Test func capture() async throws {
        let defaults = try #require(UserDefaults(suiteName: "HomeChatColorsCaptureTests.\(UUID().uuidString)"))
        let store = HomeChatColorStore(defaults: defaults)
        try store.apply(["sent": "#FFD60A", "received": "#1C2A4A"], reset: false, to: "chat")
        var images: [NSBitmapImageRep] = []
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let panel = HomeChatColorsPanel(store: store, design: DesignSettings())
            panel.show(conversation: "chat", name: "Ada", over: nil)
            let window = try #require(panel.window)
            window.appearance = NSAppearance(named: name)
            try await Task.sleep(for: .milliseconds(300))
            let frame = try #require(window.contentView?.superview ?? window.contentView)
            frame.layoutSubtreeIfNeeded()
            frame.display()
            let rep = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
            frame.cacheDisplay(in: frame.bounds, to: rep)
            images.append(rep)
            window.orderOut(nil)
        }
        let width = images.map(\.pixelsWide).reduce(0, +) + 40, height = images.map(\.pixelsHigh).max() ?? 0
        let out = NSImage(size: NSSize(width: width, height: height))
        out.lockFocus()
        NSColor(white: 0.5, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        var x = 0
        for rep in images {
            rep.draw(in: NSRect(x: x, y: height - rep.pixelsHigh, width: rep.pixelsWide, height: rep.pixelsHigh))
            x += rep.pixelsWide + 40
        }
        out.unlockFocus()
        let tiff = try #require(out.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try png.write(to: root.appendingPathComponent("chatcolors-capture.png"))
    }
}
