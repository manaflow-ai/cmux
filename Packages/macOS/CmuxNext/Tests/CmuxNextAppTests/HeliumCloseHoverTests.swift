import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// The tab x's hover is Helium's at every density (Lawrence 2026-11-13: "need to match the X icon on helium in terms
/// of hover too"). Chromium's tab_close_button.cc, which Helium keeps: the hover fill is the tab's most-contrasting
/// ink at 16 % (pressed 14 %), shown at once with no fade (`SetAnimationDuration(0)`), and the x keeps the tab's
/// title color whether hovered or not. Each case reads what a real strip's cell draws.
@MainActor @Suite(.serialized, .closesItsWindows) struct HeliumCloseHoverTests {
    nonisolated static let presets: [DensityPreset] = [.compact, .cozy, .comfortable, .spacious]

    private func components(_ color: CGColor?) -> [CGFloat] {
        guard let color, let srgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let parts = srgb.components, parts.count == 4 else { return [] }
        return parts
    }

    @Test(arguments: presets)
    func theHoverIsHeliumsSixteenPercentWithNoFade(_ preset: DensityPreset) throws {
        let design = DesignSettings.shared
        let saved = design.densityTokens
        defer { design.densityTokens = saved }
        design.densityTokens = preset.tokens
        let scene = TabConcentricCornerTests.scene()
        defer { scene.window.close() }
        for id in ["tab0", "tab1"] {
            let cell = try #require(scene.strip.cells[TabID(id)])
            cell.isHovered = true
            let close = try #require(cell.closeBackgroundLayer, "\(preset) \(id): the hovered tab shows its x")
            let glyph = try #require(cell.closeGlyphLayer)
            let title = components(cell.titleLayer.foregroundColor)
            #expect(components(glyph.strokeColor) == title, "\(preset) \(id): the x is the title's color at rest")
            #expect(close.actions?["backgroundColor"] is NSNull, "\(preset) \(id): the fill shows at once, no fade")

            cell.isCloseHovered = true
            let hover = components(close.backgroundColor)
            #expect(abs((hover.last ?? 0) - 0.16) < 0.005, "\(preset) \(id): hover fill alpha \(hover.last ?? 0), Helium 0.16")
            #expect(components(glyph.strokeColor) == title, "\(preset) \(id): the x keeps the title's color on hover")

            cell.isClosePressed = true
            let pressed = components(close.backgroundColor)
            #expect(abs((pressed.last ?? 0) - 0.14) < 0.005, "\(preset) \(id): pressed fill alpha \(pressed.last ?? 0), Helium 0.14")
            #expect(Array(pressed.prefix(3)) == Array(hover.prefix(3)), "\(preset) \(id): pressed is the same ink")
            cell.isClosePressed = false
            cell.isCloseHovered = false
            cell.isHovered = false
        }
    }
}
