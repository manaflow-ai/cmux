import AppKit
import CmuxTheme
@testable import CmuxNextDesign
@testable import CmuxNextPalette
import Testing

/// Leo, 2026-10-22, on the command palette's "No Results" page: "ALSO WHAT ABOUTTHE STYLING OF
/// THIS I THOUGHT I SAID TO GLASS IT/THEME IT PROPER". The palette, its pages, its empty state and
/// its hint bar sit on the shared overlay glass (`Glass.makeOverlayPanel`) and paint nothing solid
/// over it; its shadow falls around the glass as every popover's does (`PopupHostView`), never
/// from a view above the glass, which made the whole panel one shadow-casting group drawn under
/// its own see-through center; and the selected row is the theme accent's wash, as a themed
/// menu's highlighted row is. Reduce Transparency (the `.opaque` material) may be solid.
@MainActor @Suite(.serialized) struct PaletteStaysGlassTests {
    enum Look: String, CaseIterable { case light, dark }

    /// A theme scope with a chosen accent (violet: no system accent, not orange).
    private func scope(_ look: Look) throws -> ThemeScope {
        let scope = ThemeScope(level: .room)
        var input = switch look {
        case .light: ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x24292F))
        case .dark: ThemeInput(background: ThemeRGB(hex: 0x1E1E2E), foreground: ThemeRGB(hex: 0xCDD6F4))
        }
        input.accentColor = ThemeRGB(hex: 0x8B5CF6)
        scope.setOverride(ThemeSpec("Palette Glass \(look.rawValue)"), input: input, animated: false)
        return scope
    }

    /// The densest shared glass, as `FloatingSurfacesStayGlassTests` measures it: the neutral veils
    /// and the themed overlay tint. A fill denser than this reads as a solid card.
    private static func sharedGlassCeiling(in scope: ThemeScope) -> CGFloat {
        let veils = [FloatingGlassStyle.toast, .dialog, .card, .agentTag].flatMap { [$0.darkVeilAlpha, $0.lightVeilAlpha] }
        let tint = scope.perform { Palette.glassTint }.alphaComponent
        let overlay = min(max(tint * ChromeTunables.glassOverlayTintStrength.value, 0), 1)
        return max(CGFloat(veils.max() ?? 0), overlay) + 0.01
    }

    /// The palette as `PaletteController` shows it: its content in a clear `PalettePanel`, laid
    /// out in `scope`. A fresh model has no page and no rows, so it shows the empty state.
    private func palette(in scope: ThemeScope) -> (PaletteContentView, PalettePanel) {
        _ = NSApplication.shared
        let content = PaletteContentView(model: PaletteModel())
        let panel = PalettePanel(size: PaletteLayout.windowSize)
        panel.contentView = content
        scope.adopt(panel)
        content.layoutSubtreeIfNeeded()
        return (content, panel)
    }

    private static func surfaces(in view: NSView) -> [OverlaySurfaceView] {
        ((view as? OverlaySurfaceView).map { [$0] } ?? []) + view.subviews.flatMap(surfaces(in:))
    }

    /// The shared popup host that holds the palette's glass, if any.
    static func glassHost(of content: PaletteContentView) -> PopupHostView? {
        content.glass.superview as? PopupHostView
    }

    /// Every fill denser than `ceiling` in `root`: a layer background (a view's, or a bare
    /// sublayer's, such as a row's fill), a view that reports itself opaque, a text, scroll, clip
    /// or table view that draws a solid background, and, inside an overlay surface, any layer
    /// between its material and its content (the glass tint included).
    static func solidFills(in root: NSView, ceiling: CGFloat) -> [String] {
        var out: [String] = []
        func dense(_ color: NSColor?) -> Bool { (color?.alphaComponent ?? 0) > ceiling }
        func check(_ layer: CALayer, _ name: String) {
            if let color = layer.backgroundColor, color.alpha > ceiling { out.append("\(name) layer at \(color.alpha)") }
            for sub in layer.sublayers ?? [] where !(sub.delegate is NSView) { check(sub, "\(name) sublayer") }
        }
        func visit(_ view: NSView, path: String) {
            let name = "\(path)/\(type(of: view))"
            if let surface = view as? OverlaySurfaceView {
                out += materialFills(over: surface).filter { $0.1 > ceiling }.map { "\(name) \($0.0) at \($0.1)" }
                visit(surface.contentView, path: name)
                return
            }
            if view.isOpaque { out.append("\(name) is opaque") }
            if let layer = view.layer { check(layer, name) }
            if let field = view as? NSTextField, field.drawsBackground, dense(field.backgroundColor) { out.append("\(name) field background") }
            if let text = view as? NSTextView, text.drawsBackground, dense(text.backgroundColor) { out.append("\(name) text background") }
            if let scroll = view as? NSScrollView, scroll.drawsBackground, dense(scroll.backgroundColor) { out.append("\(name) scroll background") }
            if let clip = view as? NSClipView, clip.drawsBackground, dense(clip.backgroundColor) { out.append("\(name) clip background") }
            if let table = view as? NSTableView, dense(table.backgroundColor) { out.append("\(name) table background") }
            for sub in view.subviews { visit(sub, path: name) }
        }
        visit(root, path: "")
        return out
    }

    /// The fills between `surface`'s material and its content, outermost first: a glass panel's
    /// tint and every layer fill on the way down (`FloatingSurfacesStayGlassTests.fills(over:)`).
    private static func materialFills(over surface: OverlaySurfaceView) -> [(String, CGFloat)] {
        var chain: [NSView] = []
        var current: NSView? = surface.contentView
        while let view = current, view !== surface {
            chain.append(view)
            current = view.superview
        }
        var out: [(String, CGFloat)] = []
        var skipUntil: NSView?
        for view in chain.reversed() {
            if let skip = skipUntil {
                guard view === skip else { continue }
                skipUntil = nil
            }
            if view === surface.contentView { break }
            if let glass = view as? GlassPanelView {
                if let tint = glass.tintColor { out.append(("glass tint", tint.alphaComponent)) }
                skipUntil = glass.contentView
                continue
            }
            if let color = view.layer?.backgroundColor, color.alpha > 0 { out.append(("\(type(of: view)) fill", color.alpha)) }
        }
        return out
    }

    /// The palette with its empty state ("No Results", and its hint once something is typed) and
    /// its hint bar is the glass alone, on Liquid Glass and on the blur before macOS 26: no solid
    /// panel window, no solid fill over the glass anywhere in it.
    @Test(arguments: Look.allCases)
    func thePaletteItsEmptyStateAndItsFooterDrawNoSolidBackground(look: Look) async throws {
        let scope = try scope(look)
        let (content, panel) = palette(in: scope)
        defer { panel.orderOut(nil) }
        #expect(!panel.isOpaque, "\(look): the palette window is opaque")
        #expect(panel.backgroundColor.alphaComponent == 0, "\(look): the palette window paints a background")
        content.model.query = "tick rail"
        for _ in 0..<100 where content.emptyHint.isHidden { try await Task.sleep(for: .milliseconds(10)) }
        content.layoutSubtreeIfNeeded()
        #expect(!content.emptyTitle.isHidden, "\(look): the empty state is not shown")
        #expect(!content.emptyHint.isHidden, "\(look): the empty state's hint is not shown")
        #expect(!content.footer.isHidden && content.footer.frame.height > 0, "\(look): no footer")
        #expect(content.footer.isDescendant(of: content.glass.contentView), "\(look): the footer is not on the glass")
        #expect(content.emptyTitle.isDescendant(of: content.glass.contentView), "\(look): the empty state is not on the glass")
        let ceiling = Self.sharedGlassCeiling(in: scope)
        let surfaces = Self.surfaces(in: content)
        #expect(surfaces.contains { $0 === content.glass })
        for material in [OverlayMaterial.liquidGlass, .vibrancy] {
            surfaces.forEach { $0.materialOverride = material }
            content.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            #expect(content.glass.material == material)
            #expect(!content.glass.isCard, "\(look) \(material): the palette lays the solid card fill on its glass")
            let tints = Self.materialFills(over: content.glass)
            #expect(!tints.isEmpty, "\(look) \(material): the palette draws no glass tint")
            let solid = Self.solidFills(in: content, ceiling: ceiling)
            #expect(solid.isEmpty, "\(look) \(material): solid over the glass (ceiling \(ceiling)): \(solid)")
        }
        surfaces.forEach { $0.materialOverride = nil }
    }

    /// Reduce Transparency keeps its fallback: the palette's surface turns solid then (the popup
    /// surface), and back to glass after.
    @Test func reduceTransparencyStillDrawsTheSolidFallback() throws {
        let scope = try scope(.dark)
        let (content, panel) = palette(in: scope)
        defer { panel.orderOut(nil) }
        content.glass.materialOverride = .opaque
        let fills = content.glass.subviews.compactMap { $0.layer?.backgroundColor }
        let fill = try #require(fills.first, "Reduce Transparency's palette paints no surface")
        #expect(fill.alpha == 1, "Reduce Transparency's palette is not solid (\(fill.alpha))")
        content.glass.materialOverride = .liquidGlass
        #expect(content.glass.material == .liquidGlass)
    }

    /// No view above the glass casts a shadow (that groups the glass and draws the shadow under its
    /// see-through center); the shared popup host casts it around the glass.
    @Test func theShadowFallsAroundTheGlassNotUnderIt() throws {
        let scope = try scope(.dark)
        let (content, panel) = palette(in: scope)
        defer { panel.orderOut(nil) }
        var ancestor: NSView? = content.glass.superview
        while let view = ancestor {
            #expect(view.shadow == nil, "\(type(of: view)) above the glass casts an NSShadow")
            if !(view is PopupHostView) { #expect((view.layer?.shadowOpacity ?? 0) == 0, "\(type(of: view)) above the glass casts a layer shadow") }
            ancestor = view.superview
        }
        let host = try #require(Self.glassHost(of: content), "the palette's glass is not in the shared popup host")
        #expect(host.shadowLayer.shadowOpacity > 0)
        #expect(host.cornerRadius == PaletteLayout.cornerRadius)
        #expect(content.glass.cornerRadius == PaletteLayout.cornerRadius)
        let margin = PaletteLayout.shadowMargin
        let glassFrame = content.glass.convert(content.glass.bounds, to: content)
        #expect(abs(glassFrame.width - PaletteLayout.width) < 0.5 && abs(glassFrame.height - PaletteLayout.height) < 0.5)
        #expect(abs(glassFrame.minX - margin) < 0.5 && abs(glassFrame.minY - margin) < 0.5, "the glass moved: \(glassFrame)")
    }

    /// The selected row, here and in the Actions menu, is the theme accent's faint wash (a themed
    /// menu's highlight), translucent over the glass; never a solid bar or the system accent.
    @Test(arguments: Look.allCases)
    func theSelectedRowIsTheThemeAccentsWash(look: Look) throws {
        let scope = try scope(look)
        let (accent, highlight, chosen) = scope.perform { (Palette.accentFill, Palette.menuHighlight, Palette.hasChosenAccent) }
        #expect(chosen, "\(look): the test theme names no accent")
        let row = PaletteTableRowView(frame: NSRect(x: 0, y: 0, width: 400, height: PaletteLayout.rowHeight))
        let window = NSWindow(contentRect: row.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.contentView = row
        scope.adopt(window)
        row.isPaletteSelected = true
        row.drawBackground(in: row.bounds)
        // The row's fill: its one bare sublayer, under the cell.
        let fillLayer = try #require(row.layer?.sublayers?.first { !($0.delegate is NSView) })
        let fill = try #require(fillLayer.backgroundColor.flatMap { NSColor(cgColor: $0) }?.usingColorSpace(.sRGB))
        let expected = try #require(highlight.usingColorSpace(.sRGB))
        let hue = try #require(accent.usingColorSpace(.sRGB))
        #expect(abs(fill.redComponent - hue.redComponent) < 0.02 && abs(fill.greenComponent - hue.greenComponent) < 0.02
                && abs(fill.blueComponent - hue.blueComponent) < 0.02, "\(look): the selection \(fill) is not the accent \(hue)")
        #expect(abs(fill.alphaComponent - expected.alphaComponent) < 0.01, "\(look): the selection \(fill) is not the menu highlight \(expected)")
        #expect(fill.alphaComponent < Self.sharedGlassCeiling(in: scope), "\(look): the selection is a solid bar")
    }

    /// The check is not vacuous: a solid fill on the footer, or the card fill on the glass, fails it.
    @Test func aSolidFooterOrCardFillFailsTheCheck() throws {
        let scope = try scope(.dark)
        let (content, panel) = palette(in: scope)
        defer { panel.orderOut(nil) }
        let ceiling = Self.sharedGlassCeiling(in: scope)
        content.glass.materialOverride = .liquidGlass
        #expect(Self.solidFills(in: content, ceiling: ceiling).isEmpty)
        content.footer.wantsLayer = true
        content.footer.layer?.backgroundColor = scope.perform { Palette.popupSurface }.cgColor
        #expect(Self.solidFills(in: content, ceiling: ceiling).contains { $0.contains("PaletteFooterView") })
        content.footer.layer?.backgroundColor = nil
        let card = Glass.makeOverlayPanel(content: NSView(), cornerRadius: PaletteLayout.cornerRadius, cardFill: true)
        scope.root(card)
        card.materialOverride = .liquidGlass
        card.applyTheme()
        #expect(!Self.solidFills(in: card, ceiling: ceiling).isEmpty, "the card fill passes the check")
    }
}
