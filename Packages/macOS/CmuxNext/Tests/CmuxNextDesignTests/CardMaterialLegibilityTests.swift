import AppKit
import CmuxNextTestSupport
import CmuxTheme
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// Lawrence, 2026-10-20: "The card is potentially too liquid glassy so it is very hard to see and
/// use. Like the floating card when I hover over workspaces and tabs." Every floating card that
/// carries text (`Glass.makeOverlayPanel`: hover cards, the update card, popovers, the palette)
/// paints, on the glass or blur, a fill dense enough that its primary and secondary text keep
/// WCAG AA (4.5:1) over any backdrop (pure black and pure white are the worst a blur can do), and
/// a visible 1px rim that sets it apart from what is behind it.
@MainActor @Suite(.serialized, .closesItsWindows) struct CardMaterialLegibilityTests {
    private static let themes: [(String, ThemeInput)] = [
        ("light", ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x24292F))),
        ("dark", ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xD4D4D4))),
        ("solarized", ThemeInput(background: ThemeRGB(hex: 0x002B36), foreground: ThemeRGB(hex: 0x839496))),
        ("see-through", ThemeInput(background: ThemeRGB(hex: 0x2B1650), foreground: ThemeRGB(hex: 0xF4E3FF),
                                   backgroundOpacity: 0.6)),
    ]

    private struct Mounted {
        let window: NSWindow
        let scope: ThemeScope
        let panel: OverlaySurfaceView
    }

    private func mount(_ input: ThemeInput, _ name: String, material: OverlayMaterial) throws -> Mounted {
        let scope = ThemeScope(level: .room)
        scope.setOverride(try #require(ThemeSpec("Card \(name)")), input: input, animated: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        // The test owns the window; a close must not release it a second time.
        window.isReleasedWhenClosed = false
        let root = try #require(window.contentView)
        scope.root(root)
        // The card fill is opt-in since 2026-10-21 (overlays are the shared glass alone); this
        // checks the fill itself, for a surface that opts in and for the web's --cmux-card-tint.
        let panel = Glass.makeOverlayPanel(content: NSTextField(labelWithString: "Workspace"),
                                           cornerRadius: PopupStyle.standard.cornerRadius, cardFill: true)
        panel.frame = NSRect(x: 10, y: 10, width: 240, height: 120)
        root.addSubview(panel)
        panel.materialOverride = material
        panel.applyTheme()
        return Mounted(window: window, scope: scope, panel: panel)
    }

    /// The views from the surface down to its content, outermost first.
    private static func path(to content: NSView, in surface: NSView) -> [NSView] {
        var chain: [NSView] = []
        var current: NSView? = content
        while let view = current, view !== surface {
            chain.append(view)
            current = view.superview
        }
        return chain.reversed()
    }

    /// The fills drawn behind the content, outermost first: a glass panel's tint (its own
    /// internals stand for it) and every layer background on the way down.
    private static func fills(_ panel: OverlaySurfaceView) -> [NSColor] {
        var fills: [NSColor] = []
        var skipUntil: NSView?
        for view in path(to: panel.contentView, in: panel) {
            if let skip = skipUntil {
                guard view === skip else { continue }
                skipUntil = nil
            }
            if let glass = view as? GlassPanelView {
                if let tint = glass.tintColor { fills.append(tint) }
                skipUntil = glass.contentView
                continue
            }
            if view === panel.contentView { break }
            if let color = view.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)) { fills.append(color) }
        }
        return fills
    }

    private static func rgb(_ color: NSColor) -> ThemeRGB {
        let c = color.usingColorSpace(.sRGB) ?? color
        return ThemeRGB(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent),
                        alpha: Double(c.alphaComponent))
    }

    private static func composite(_ fills: [NSColor], over backdrop: ThemeRGB) -> ThemeRGB {
        fills.reduce(backdrop) { base, fill in rgb(fill).composited(over: base) }
    }

    @Test(arguments: [OverlayMaterial.liquidGlass, .vibrancy])
    func cardTextKeepsAAOverAnyBackdrop(material: OverlayMaterial) throws {
        for (name, input) in Self.themes {
            let mounted = try mount(input, name, material: material)
            let fills = Self.fills(mounted.panel)
            let primary = Self.rgb(mounted.scope.perform { Palette.textPrimary }).withAlpha(1)
            let secondary = Self.rgb(mounted.scope.perform { Palette.textSecondary }).withAlpha(1)
            for backdrop in [ThemeRGB(hex: 0x000000), ThemeRGB(hex: 0xFFFFFF), ThemeRGB(hex: 0x808080)] {
                let surface = Self.composite(fills, over: backdrop)
                #expect(primary.contrast(with: surface) >= ThemeTokens.minimumTextContrast,
                        "\(name) \(material): primary \(primary.contrast(with: surface)) over \(backdrop)")
                #expect(secondary.contrast(with: surface) >= ThemeTokens.minimumTextContrast,
                        "\(name) \(material): secondary \(secondary.contrast(with: surface)) over \(backdrop)")
            }
            // Mostly opaque: the backdrop shows only faintly through the card.
            let coverage = 1 - fills.reduce(1.0) { $0 * (1 - Double(Self.rgb($1).alpha)) }
            #expect(coverage >= 0.85, "\(name) \(material): card covers \(coverage)")
            mounted.window.close()
        }
    }

    @Test(arguments: [OverlayMaterial.liquidGlass, .vibrancy, .opaque])
    func cardHasAVisibleRim(material: OverlayMaterial) throws {
        let (name, input) = Self.themes[1]
        let mounted = try mount(input, name, material: material)
        let layers = Self.path(to: mounted.panel.contentView, in: mounted.panel).compactMap(\.layer)
        let rim = layers.first { $0.borderWidth > 0 && ($0.borderColor?.alpha ?? 0) > 0 }
        #expect(rim != nil, "\(material): no rim")
        if let rim {
            let scale = mounted.window.backingScaleFactor
            #expect(rim.borderWidth * scale >= 1, "\(material): rim under one device pixel")
        }
        mounted.window.close()
    }
}
