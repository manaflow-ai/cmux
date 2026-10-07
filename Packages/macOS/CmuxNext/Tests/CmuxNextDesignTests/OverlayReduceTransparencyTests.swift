import AppKit
import Testing
@testable import CmuxNextDesign

/// Under Reduce Transparency every floating overlay (palette, hover card,
/// find and prompt bars, drop overlay) is opaque: the window background
/// moved 14% toward the primary text (design tokens, materials.overlay).
/// The state is injected through `ReduceTransparency.shared.override`; the system
/// setting is never touched.
@MainActor @Suite struct OverlayReduceTransparencyTests {
    /// mix(window, textPrimary, 0.14), written out so the test does not reuse
    /// the code under test.
    private func expectedFill(_ tokens: ThemeTokens) -> ThemeRGB {
        let w = tokens.windowBackground, t = tokens.textPrimary
        let f = 0.14
        return ThemeRGB(red: w.red + (t.red - w.red) * f, green: w.green + (t.green - w.green) * f,
                        blue: w.blue + (t.blue - w.blue) * f)
    }

    private func expectColor(_ color: CGColor?, _ expected: ThemeRGB, _ label: String) throws {
        let rgb = try #require(color.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }, "\(label)")
        #expect(abs(rgb.redComponent - expected.red) < 0.002, "\(label)")
        #expect(abs(rgb.greenComponent - expected.green) < 0.002, "\(label)")
        #expect(abs(rgb.blueComponent - expected.blue) < 0.002, "\(label)")
        #expect(rgb.alphaComponent == 1, "\(label)")
    }

    @Test func theFallbackTokenIsTheWindowMixedTowardTheText() {
        #expect(ChromeTunables.opaqueOverlayLift.defaultValue == 0.14)
        for (name, input) in ThemeFixtures.all {
            let tokens = ThemeTokens.derive(from: input)
            let fill = tokens.opaqueOverlayFill(lift: ChromeTunables.opaqueOverlayLift.defaultValue)
            let expected = expectedFill(tokens)
            #expect(abs(fill.red - expected.red) < 1e-9 && abs(fill.green - expected.green) < 1e-9
                && abs(fill.blue - expected.blue) < 1e-9, "\(name)")
            #expect(fill.alpha == 1, "\(name)")
        }
    }

    /// A translucent window background (background-opacity < 1) still gives
    /// an opaque fill.
    @Test func theFallbackIsOpaqueOverATranslucentWindow() {
        let tokens = ThemeTokens.derive(from: ThemeInput(background: ThemeRGB(hex: 0x101010), foreground: .white,
                                                         palette: [], backgroundOpacity: 0.5))
        #expect(tokens.opaqueOverlayFill(lift: 0.14).alpha == 1)
    }

    @Test func eachThemeDrawsItsFallbackOnTheSurface() throws {
        ReduceTransparency.shared.override = true
        defer { ReduceTransparency.shared.override = nil }
        for (name, input) in ThemeFixtures.all {
            let room = ThemeScope(level: .room)
            room.setOverride(ThemeSpec("Overlay \(name)")!, input: input, animated: false)
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
            room.root(host)
            let surface = Glass.makeOverlayPanel()
            host.addSubview(surface)
            surface.applyTheme()
            #expect(surface.material == .opaque, "\(name)")
            try expectColor(surface.materialDrawingView?.layer?.backgroundColor, expectedFill(ThemeTokens.derive(from: input)), name)
        }
    }

    @Test func aThemeChangeRecolorsTheFallbackLive() throws {
        ReduceTransparency.shared.override = true
        defer { ReduceTransparency.shared.override = nil }
        let room = ThemeScope(level: .room)
        room.setOverride(ThemeSpec("Gruvbox Dark")!, input: ThemeFixtures.gruvboxDark, animated: false)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        room.root(host)
        let surface = Glass.makeOverlayPanel()
        host.addSubview(surface)
        surface.applyTheme()
        try expectColor(surface.materialDrawingView?.layer?.backgroundColor, expectedFill(ThemeTokens.derive(from: ThemeFixtures.gruvboxDark)), "dark")
        // The scope repaints its views (no call from the test).
        room.setOverride(ThemeSpec("GitHub Light")!, input: ThemeFixtures.githubLight, animated: false)
        try expectColor(surface.materialDrawingView?.layer?.backgroundColor, expectedFill(ThemeTokens.derive(from: ThemeFixtures.githubLight)), "light")
    }

    @Test func theSettingSwitchesLiveSurfacesBothWays() {
        ReduceTransparency.shared.override = false
        defer { ReduceTransparency.shared.override = nil }
        let surface = Glass.makeOverlayPanel()
        let label = NSTextField(labelWithString: "Find")
        surface.contentView.addSubview(label)
        #expect(surface.material == .liquidGlass)
        #expect(surface.materialDrawingView is NSGlassEffectView)
        ReduceTransparency.shared.override = true
        #expect(surface.material == .opaque)
        #expect(!(surface.materialDrawingView is NSGlassEffectView))
        #expect(label.superview === surface.contentView && surface.contentView.isDescendant(of: surface))
        ReduceTransparency.shared.override = false
        #expect(surface.material == .liquidGlass)
        #expect(surface.materialDrawingView is NSGlassEffectView)
    }

    /// The system path: the accessibility change notification redraws the
    /// surfaces of that source, read from its injected setting.
    @Test func theAccessibilityNotificationSwitchesTheSurfaces() {
        var system = false
        let changes = NotificationCenter()
        let source = ReduceTransparency(system: { system }, changes: changes)
        let surface = OverlaySurfaceView(interactive: true, reduceTransparency: source)
        #expect(surface.material == .liquidGlass)
        system = true
        #expect(surface.material == .liquidGlass, "nothing changes before the notification")
        changes.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        #expect(surface.material == .opaque)
        system = false
        changes.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        #expect(surface.material == .liquidGlass)
    }

    /// A pinned material (drop highlight debug) ignores the setting.
    @Test func aPinnedMaterialIgnoresTheSetting() {
        ReduceTransparency.shared.override = false
        defer { ReduceTransparency.shared.override = nil }
        let surface = OverlaySurfaceView(material: .liquidGlass)
        ReduceTransparency.shared.override = true
        #expect(surface.material == .liquidGlass)
    }

    /// Panels (find bar, prompt bar, hover card) size from their content
    /// through constraints, on every material.
    @Test func constraintContentSizesThePanelOnEveryMaterial() {
        for material in [OverlayMaterial.liquidGlass, .vibrancy, .opaque] {
            let surface = OverlaySurfaceView(material: material, interactive: true)
            let box = NSView()
            box.translatesAutoresizingMaskIntoConstraints = false
            surface.contentView.addSubview(box)
            NSLayoutConstraint.activate([
                box.widthAnchor.constraint(equalToConstant: 180),
                box.heightAnchor.constraint(equalToConstant: 44),
                box.leadingAnchor.constraint(equalTo: surface.contentView.leadingAnchor),
                box.trailingAnchor.constraint(equalTo: surface.contentView.trailingAnchor),
                box.topAnchor.constraint(equalTo: surface.contentView.topAnchor),
                box.bottomAnchor.constraint(equalTo: surface.contentView.bottomAnchor),
            ])
            surface.layoutSubtreeIfNeeded()
            #expect(surface.fittingSize == NSSize(width: 180, height: 44), "\(material): \(surface.fittingSize)")
        }
    }

    /// Panels take clicks; pure overlays (drop target) let them through.
    @Test func panelsTakeClicksAndOverlaysDoNot() {
        let panel = Glass.makeOverlayPanel()
        panel.frame = NSRect(x: 0, y: 0, width: 100, height: 40)
        #expect(panel.hitTest(NSPoint(x: 50, y: 20)) != nil)
        let overlay = OverlaySurfaceView(material: .opaque)
        overlay.frame = NSRect(x: 0, y: 0, width: 100, height: 40)
        #expect(overlay.hitTest(NSPoint(x: 50, y: 20)) == nil)
    }

    @Test func theHoverCardResolvesThroughTheOverlaySurface() {
        ReduceTransparency.shared.override = true
        defer { ReduceTransparency.shared.override = nil }
        let card = HoverCardPanel()
        #expect(card.contentView === card.glass)
        #expect(card.glass.material == .opaque)
        #expect(!(card.glass.materialDrawingView is NSGlassEffectView))
        ReduceTransparency.shared.override = false
        #expect(card.glass.material == .liquidGlass)
    }
}
