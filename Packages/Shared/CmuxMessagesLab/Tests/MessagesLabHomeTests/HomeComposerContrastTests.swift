import AppKit
import CmuxHomeRender
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// The Home composer's typed text, placeholder and file names read on the field in light and dark
/// themes, in both bubble styles and with a chat's Chat Colors (user 2026-10-19, u4476: "composer
/// input, text, placeholder and label colors look dark"). Every text colour the field draws meets
/// WCAG AA (4.5:1) on the field; a theme change recolours a draft already typed.
///
/// `composerContrastGallery` writes `.build/composer-contrast-gallery.png`: one row per theme and
/// style, the old colours (left) beside the new ones (right), each with its contrast ratios.
@MainActor @Suite(.serialized) struct HomeComposerContrastTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let theme: HomePalette.Theme
        let style: Style
        var testDescription: String { "\(name) \(style)" }
    }

    enum Style: Sendable, CustomStringConvertible {
        case iMessage, theme
        /// iMessage's style with Chat Colors that pick a light received bubble with dark text.
        case chatColors
        var description: String {
            switch self {
            case .iMessage: "iMessage"
            case .theme: "theme"
            case .chatColors: "chat colors"
            }
        }
    }

    nonisolated static let themes: [(String, HomePalette.Theme)] = [
        ("light", .init(background: .gray255(255), foreground: .gray255(29),
                        accent: .rgb255(2, 132, 254), failure: .rgb255(215, 0, 21))),
        ("dark", .init(background: .gray255(30), foreground: .gray255(230),
                       accent: .rgb255(2, 132, 254), failure: .rgb255(255, 69, 58))),
        ("dracula", .init(background: .rgb255(40, 42, 54), foreground: .rgb255(248, 248, 242),
                          accent: .rgb255(189, 147, 249), failure: .rgb255(255, 85, 85))),
        ("solarized-light", .init(background: .rgb255(253, 246, 227), foreground: .rgb255(101, 123, 131),
                                  accent: .rgb255(38, 139, 210), failure: .rgb255(220, 50, 47))),
    ]
    nonisolated static let cases: [Case] = themes.flatMap { name, theme in
        [Style.iMessage, .theme, .chatColors].map { Case(name: name, theme: theme, style: $0) }
    }

    static func palette(_ c: Case) -> HomePalette {
        switch c.style {
        case .iMessage: HomePalette.iMessageStyled(c.theme)
        case .theme: HomePalette.themeStyled(c.theme)
        case .chatColors: HomePalette.iMessageStyled(c.theme)
            .applying(HomeBubbleColors(received: .rgb255(250, 236, 180), receivedText: .rgb255(40, 30, 10)))
        }
    }

    // MARK: Colour arithmetic (WCAG 2.x)

    struct RGBA { var r, g, b, a: CGFloat }
    static func rgba(_ c: NSColor) -> RGBA {
        let s = c.usingColorSpace(.sRGB) ?? c
        return RGBA(r: s.redComponent, g: s.greenComponent, b: s.blueComponent, a: s.alphaComponent)
    }
    static func rgba(_ c: HomeColor) -> RGBA { RGBA(r: c.red, g: c.green, b: c.blue, a: c.alpha) }
    /// `top` composited over the opaque `bottom`.
    static func over(_ top: RGBA, _ bottom: RGBA) -> RGBA {
        RGBA(r: top.r * top.a + bottom.r * (1 - top.a), g: top.g * top.a + bottom.g * (1 - top.a),
             b: top.b * top.a + bottom.b * (1 - top.a), a: 1)
    }
    static func luminance(_ c: RGBA) -> Double {
        func lin(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }
    /// The contrast of `ink` drawn on `surface` (both composited over `under` first).
    static func contrast(_ ink: RGBA, on surface: RGBA, under: RGBA) -> Double {
        let field = over(surface, under), shown = over(ink, field)
        let a = luminance(shown), b = luminance(field)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// The field's colour as the palette paints it, over the page.
    static func field(_ p: HomePalette) -> (surface: RGBA, page: RGBA) {
        (rgba(p.composeGlass), over(rgba(p.background), RGBA(r: 0, g: 0, b: 0, a: 1)))
    }

    // MARK: Behaviour

    @Test(arguments: cases)
    func typedTextAndPlaceholderReadOnTheField(_ c: Case) throws {
        let palette = Self.palette(c)
        let box = PaletteScope.box(for: FixtureTheme(active: palette))
        let (surface, page) = Self.field(palette)
        try PaletteScope.with(box) {
            let typed = try #require(ComposeView.typing[.foregroundColor] as? NSColor)
            let typedRatio = Self.contrast(Self.rgba(typed), on: surface, under: page)
            #expect(typedRatio >= 4.5, "typed text \(typedRatio)")
            let placeholderRatio = Self.contrast(Self.rgba(Fixture.placeholder), on: surface, under: page)
            #expect(placeholderRatio >= 4.5, "placeholder \(placeholderRatio)")
        }
    }

    /// A chat whose Chat Colors give received bubbles dark text keeps the theme's text in the field:
    /// dark text on a dark field was the "input text looks dark" report.
    @Test func typedTextIsTheComposersNotTheReceivedBubbles() throws {
        let c = try #require(Self.cases.first { $0.name == "dark" && $0.style == .chatColors })
        let palette = Self.palette(c)
        let box = PaletteScope.box(for: FixtureTheme(active: palette))
        try PaletteScope.with(box) {
            let typed = try #require(ComposeView.typing[.foregroundColor] as? NSColor)
            #expect(Self.rgba(typed).r > 0.8, "the dark theme's light text, not the bubble's dark ink")
        }
    }

    /// A draft typed under a light theme turns the dark theme's text when the theme changes.
    @Test func aThemeChangeRecoloursTheDraft() throws {
        let light = try #require(Self.cases.first { $0.name == "light" && $0.style == .iMessage })
        let dark = try #require(Self.cases.first { $0.name == "dark" && $0.style == .iMessage })
        let lightBox = PaletteScope.box(for: FixtureTheme(active: Self.palette(light)))
        let darkBox = PaletteScope.box(for: FixtureTheme(active: Self.palette(dark)))
        let compose = PaletteScope.with(lightBox) { ComposeView(frame: NSRect(x: 0, y: 0, width: 480, height: 1041)) }
        let tv = compose.textView.view
        PaletteScope.with(lightBox) { tv.insertText("draft", replacementRange: NSRange(location: 0, length: 0)) }
        PaletteScope.with(darkBox) { compose.rescale() }
        let storage = try #require(tv.textStorage)
        try #require(storage.length > 0)
        let shown = try #require(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        let want = PaletteScope.with(darkBox) { Fixture.composeText }
        #expect(Self.rgba(shown).r == Self.rgba(want).r && Self.rgba(shown).g == Self.rgba(want).g)
        let next = try #require(tv.typingAttributes[.foregroundColor] as? NSColor)
        #expect(Self.rgba(next).r == Self.rgba(want).r)
    }

    // MARK: Gallery

    /// The variants side by side: before (MessagesLab's dark placeholder ink, the received text as the
    /// typed text) and after (the composer's own text, the palette's placeholder), with each ratio.
    @Test func composerContrastGallery() throws {
        let rowH: CGFloat = 64, colW: CGFloat = 520, labelW: CGFloat = 200
        let width = labelW + colW * 2, height = rowH * CGFloat(Self.cases.count) + 40
        let scale: CGFloat = 2
        let context = try #require(CGContext(
            data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.scaleBy(x: scale, y: scale)
        let ns = NSGraphicsContext(cgContext: context, flipped: true)
        context.translateBy(x: 0, y: height); context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSColor(white: 0.5, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
        func text(_ s: String, _ color: NSColor, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 13) {
            NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color])
                .draw(at: NSPoint(x: x, y: y))
        }
        text("theme / style", .white, 12, 12, size: 12)
        text("before", .white, labelW + 12, 12, size: 12)
        text("after (4.5:1 on the field)", .white, labelW + colW + 12, 12, size: 12)
        for (i, c) in Self.cases.enumerated() {
            let palette = Self.palette(c)
            let theme = FixtureTheme(active: palette)
            let box = PaletteScope.box(for: theme)
            let y = 40 + CGFloat(i) * rowH
            text(c.testDescription, .white, 12, y + 22, size: 12)
            let (surface, page) = Self.field(palette)
            let after = PaletteScope.with(box) {
                (typed: (ComposeView.typing[.foregroundColor] as? NSColor) ?? .black, placeholder: Fixture.placeholder,
                 label: Fixture.secondaryText)
            }
            let before = (typed: theme.active.incomingText,
                          placeholder: theme.active.isLight ? theme.active.placeholder : NSColor(white: 1, alpha: 0.316),
                          label: theme.active.secondaryText)
            for (col, inks) in [before, after].enumerated() {
                let x = labelW + CGFloat(col) * colW
                theme.active.background.setFill(); NSRect(x: x, y: y, width: colW, height: rowH).fill()
                for (j, (s, ink)) in [("Message", inks.placeholder), ("Typed draft", inks.typed)].enumerated() {
                    let r = NSRect(x: x + 10 + CGFloat(j) * 170, y: y + 8, width: 160, height: 30)
                    let path = NSBezierPath(roundedRect: r, xRadius: 15, yRadius: 15)
                    theme.active.palette.composeGlass.nsColor.setFill(); path.fill()
                    if theme.active.isLight { theme.active.fieldEdge.setStroke(); path.lineWidth = 1; path.stroke() }
                    text(s, ink, r.minX + 12, r.minY + 6)
                    let ratio = Self.contrast(Self.rgba(ink), on: surface, under: page)
                    text(String(format: "%.1f:1", ratio), theme.active.secondaryText, r.minX + 12, r.maxY + 4, size: 10)
                }
                text("Delivered", inks.label, x + 360, y + 14)
                let labelRatio = Self.contrast(Self.rgba(inks.label), on: page, under: page)
                text(String(format: "%.1f:1", labelRatio), inks.label, x + 360, y + 34, size: 10)
            }
        }
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let output = package.appendingPathComponent(".build/composer-contrast-gallery.png")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = try #require(CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        if let out = ProcessInfo.processInfo.environment["FAST_CHECKS_OUT"] {
            try? FileManager.default.copyItem(at: output, to: URL(fileURLWithPath: out).appendingPathComponent("composer-contrast-gallery.png"))
        }
    }
}

private extension HomeColor {
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}
