import AppKit
import CmuxTheme
@testable import CmuxNextDesign
import Testing

/// Leo, 2026-10-12: popovers, hover cards, the palette and the find bars were glass, so the text
/// under them showed through and read as text on text. Every overlay that carries text is the
/// one solid popup surface (the theme's opaque overlay fill), whatever this Mac's transparency
/// setting, and pages get the same color (`--cmux-popup-surface`) for their menus and tooltips.
@MainActor @Suite(.serialized) struct PopupSurfaceTests {
    /// A see-through theme: its elevated background is translucent, the popup surface must not be.
    private let input = ThemeInput(background: ThemeRGB(hex: 0x2B1650), foreground: ThemeRGB(hex: 0xF4E3FF),
                                   backgroundOpacity: 0.6)

    @Test func overlayPanelsAreTheOpaquePopupSurface() throws {
        let scope = ThemeScope(level: .room)
        scope.setOverride(try #require(ThemeSpec("Stress Purple")), input: input, animated: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let root = try #require(window.contentView)
        scope.root(root)
        let expected = scope.tokens.opaqueOverlayFill(lift: ChromeTunables.opaqueOverlayLift.value).nsColor

        // The palette's, a hover card's or popover's, and a find bar's.
        for radius in [Metrics.panelCornerRadius, PopupStyle.standard.cornerRadius, 6] {
            let panel = Glass.makeOverlayPanel(content: NSTextField(labelWithString: "Find"), cornerRadius: radius)
            panel.frame = NSRect(x: 10, y: 10, width: 200, height: 80)
            root.addSubview(panel)
            panel.applyTheme()
            #expect(panel.material == .opaque, "radius \(radius)")
            let fill = try #require(panel.subviews.first?.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)),
                                    "radius \(radius)")
            #expect(Self.same(fill, expected), "radius \(radius): \(fill) vs \(expected)")
            #expect(panel.subviews.first?.layer?.cornerRadius == radius)
            panel.removeFromSuperview()
        }
    }

    @Test func pagesGetTheSamePopupSurface() throws {
        let tokens = ThemeTokens.derive(from: input)
        let fill = tokens.opaqueOverlayFill(lift: ChromeTunables.opaqueOverlayLift.value)
        #expect(fill.alpha == 1)
        let popup = try #require(WebTheme(tokens, surface: .internalPage, backgrounds: .none).variables["--cmux-popup-surface"])
        #expect(popup == WebTheme.css(fill))
    }

    static func same(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let lhs = lhs.usingColorSpace(.sRGB), let rhs = rhs.usingColorSpace(.sRGB) else { return false }
        return abs(lhs.redComponent - rhs.redComponent) < 0.01 && abs(lhs.greenComponent - rhs.greenComponent) < 0.01
            && abs(lhs.blueComponent - rhs.blueComponent) < 0.01 && abs(lhs.alphaComponent - rhs.alphaComponent) < 0.01
    }
}
