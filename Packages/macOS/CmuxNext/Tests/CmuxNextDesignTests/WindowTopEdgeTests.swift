import AppKit
import CmuxNextDesign
import CmuxNextDesignTokens
import Testing

/// The user, 2026-11-19, on the nightly with Clear Glass over a picture: "weird white border at top
/// of window we gotta fix". AppKit's titlebar decoration (`_NSTitlebarDecorationView`, a CoreUI
/// frame layer 32 pt tall) paints a one-pixel white line at about 10% along a titled window's top
/// edge, in light and dark. The window's own rim already runs around all four sides, so the top
/// read as a second, brighter line. A window whose content runs under a transparent titlebar draws
/// its top edge like the other three: the row at the top edge is the content's color.
@MainActor @Suite(.serialized) struct WindowTopEdgeTests {
    /// A window as cmux makes one (content under a transparent titlebar) over a solid fill.
    private static func window(kind: WindowKind, dark: Bool) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(white: dark ? 0.18 : 0.85, alpha: 1).cgColor
        window.install(kind: kind, content: content, scope: ThemeScope(level: .room), activeLook: nil)
        return window
    }

    /// Gray level (0-255) of `rep`'s pixel at the horizontal middle of row `y` (0 is the top row).
    private static func level(_ rep: NSBitmapImageRep, row y: Int) throws -> Double {
        let color = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: y)?.usingColorSpace(.deviceRGB))
        return (color.redComponent + color.greenComponent + color.blueComponent) / 3 * 255
    }

    @Test(arguments: [WindowKind.main, .onboarding], [true, false])
    func theTopEdgeIsTheContentsColorLikeTheOtherEdges(kind: WindowKind, dark: Bool) throws {
        let window = Self.window(kind: kind, dark: dark)
        defer { window.close() }
        // The whole frame view, titlebar included: what the window itself draws inside its edge.
        let frame = try #require(window.contentView?.superview)
        frame.layoutSubtreeIfNeeded()
        let rep = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: rep)
        let scale = max(1, Int((Double(rep.pixelsWide) / frame.bounds.width).rounded()))
        let inside = try Self.level(rep, row: 4 * scale)
        let bottom = try Self.level(rep, row: rep.pixelsHigh - 1)
        for row in 0..<scale {
            let top = try Self.level(rep, row: row)
            #expect(abs(top - inside) < 1.5, "\(kind) \(dark ? "dark" : "light") @\(scale)x: top row \(row) is \(top), the content \(inside)")
            #expect(abs(top - bottom) < 1.5, "the top edge \(top) matches the bottom edge \(bottom)")
        }
    }
}
