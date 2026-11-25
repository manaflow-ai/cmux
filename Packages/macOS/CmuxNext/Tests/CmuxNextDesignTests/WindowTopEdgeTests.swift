import AppKit
import CmuxNextDesign
import CmuxNextDesignTokens
import Testing

/// The user, 2026-11-19, on the nightly with Clear Glass over a picture: "weird white border at top
/// of window we gotta fix". AppKit's titlebar decoration (`_NSTitlebarDecorationView`, a CoreUI
/// frame layer as tall as the titlebar) paints a one-pixel white line at about 10% along a titled
/// window's top edge, in light and dark. The window's own rim already runs around all four sides,
/// so the top read as a second, brighter line. A window whose content runs under a transparent
/// titlebar draws its top edge like the other three: the row at the top edge is the content's color.
///
/// The line is drawn by the window server's frame layer, so it shows only in a session with a
/// screen; a host that does not draw it on a plain window (the control below) cannot show the bug.
@MainActor @Suite(.serialized, .enabled(if: !NSScreen.screens.isEmpty, "needs a display: AppKit draws the titlebar decoration only with one"))
struct WindowTopEdgeTests {
    /// A window as cmux makes one (content under a transparent titlebar) over a solid fill, given its
    /// content through the window kit (`install`), or set directly (the control: AppKit's own look).
    private static func window(kind: WindowKind?, dark: Bool) -> NSWindow {
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
        if let kind {
            window.install(kind: kind, content: content, scope: ThemeScope(level: .room), activeLook: nil)
        } else {
            window.contentView = content
        }
        return window
    }

    /// The whole frame view, titlebar included: what the window itself draws inside its edge.
    private static func image(of window: NSWindow) throws -> NSBitmapImageRep {
        let frame = try #require(window.contentView?.superview)
        frame.layoutSubtreeIfNeeded()
        let rep = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: rep)
        return rep
    }

    /// Gray level (0-255) of `rep`'s pixel at the horizontal middle of row `y` (0 is the top row).
    private static func level(_ rep: NSBitmapImageRep, row y: Int) throws -> Double {
        let color = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: y)?.usingColorSpace(.deviceRGB))
        return (color.redComponent + color.greenComponent + color.blueComponent) / 3 * 255
    }

    @Test(arguments: [WindowKind.main, .onboarding], [true, false])
    func theTopEdgeIsTheContentsColorLikeTheOtherEdges(kind: WindowKind, dark: Bool) throws {
        let control = Self.window(kind: nil, dark: dark)
        defer { control.close() }
        let plain = try Self.image(of: control)
        // AppKit's line on a plain window: without it on this host there is nothing to hide.
        guard try Self.level(plain, row: 0) - Self.level(plain, row: plain.pixelsHigh - 1) > 4 else { return }

        let window = Self.window(kind: kind, dark: dark)
        defer { window.close() }
        let rep = try Self.image(of: window)
        let scale = max(1, Int((Double(rep.pixelsWide) / 320).rounded()))
        let inside = try Self.level(rep, row: 4 * scale)
        let bottom = try Self.level(rep, row: rep.pixelsHigh - 1)
        for row in 0..<scale {
            let top = try Self.level(rep, row: row)
            #expect(abs(top - inside) < 1.5, "\(kind) \(dark ? "dark" : "light") @\(scale)x: top row \(row) is \(top), the content \(inside)")
            #expect(abs(top - bottom) < 1.5, "the top edge \(top) matches the bottom edge \(bottom)")
        }
    }
}
