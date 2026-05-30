import Testing
@testable import CmuxAppearance

@Suite("Aurean theme layer")
struct AureanPaletteTests {

    @Test("Hex parsing yields correct sRGB components")
    func hexParsing() {
        let c = AureanColor(hex: "#161819")
        #expect(abs(c.red - 0x16 / 255.0) < 1e-9)
        #expect(abs(c.green - 0x18 / 255.0) < 1e-9)
        #expect(abs(c.blue - 0x19 / 255.0) < 1e-9)
        #expect(c.alpha == 1)
    }

    @Test("Leading hash is optional and parsing is case-insensitive")
    func hexFlexibility() {
        #expect(AureanColor(hex: "ffffff") == AureanColor(hex: "#FFFFFF"))
        #expect(AureanColor(hex: "#abcdef") == AureanColor(hex: "ABCDEF"))
    }

    @Test("8-digit hex carries alpha")
    func hexAlpha() {
        let c = AureanColor(hex: "#00000080")
        #expect(abs(c.alpha - 0x80 / 255.0) < 1e-9)
    }

    @Test("Invalid hex falls back to opaque black, never crashes")
    func hexInvalid() {
        let c = AureanColor(hex: "nope")
        #expect(c == AureanColor(red: 0, green: 0, blue: 0, alpha: 1))
    }

    @Test("Cool is the default palette with the delivered token values")
    func coolDefault() {
        let p = AureanPalette()
        #expect(p.variant == .cool)
        #expect(p.surfacePrimary == AureanColor(hex: "#161819"))
        #expect(p.surfaceOff == AureanColor(hex: "#121314"))
        #expect(p.surfaceAbyssal == AureanColor(hex: "#0E1011"))
        #expect(p.text == AureanColor(hex: "#C4C7CC"))
        #expect(p.accent == AureanColor(hex: "#B8D8E8"))
        #expect(p.ok == AureanColor(hex: "#B6D4B0"))
    }

    @Test("warn and crit signals are identical across every palette (muscle memory)")
    func signalsInvariant() {
        let gold = AureanColor(hex: "#E5C07B")
        let rust = AureanColor(hex: "#FF8A66")
        for variant in AureanPaletteVariant.allCases {
            let p = variant.palette
            #expect(p.warn == gold, "warn drifted in \(variant)")
            #expect(p.crit == rust, "crit drifted in \(variant)")
        }
    }

    @Test("Every palette differs in negative space (no accidental duplicates)")
    func variantsDistinct() {
        let primaries = Set(AureanPaletteVariant.allCases.map { $0.palette.surfacePrimary })
        #expect(primaries.count == AureanPaletteVariant.allCases.count)
    }

    @Test("Opacity projection keeps hue, replaces alpha")
    func opacityProjection() {
        let p = AureanPalette()
        let border = p.text(.border)
        #expect(border.red == p.text.red)
        #expect(border.green == p.text.green)
        #expect(border.blue == p.text.blue)
        #expect(abs(border.alpha - 0.236) < 1e-9)
    }

    @Test("Opacity ladder follows the 1/φⁿ stops")
    func opacityLadder() {
        #expect(AureanOpacity.organic.value == 0.618)
        #expect(AureanOpacity.secondary.value == 0.382)
        #expect(AureanOpacity.border.value == 0.236)
        #expect(AureanOpacity.faint.value == 0.145)
    }

    @Test("Golden split shares are φ-derived and sum to one")
    func goldenSplit() {
        #expect(abs(AureanMetrics.Split.major - 0.618033988749) < 1e-9)
        #expect(abs(AureanMetrics.Split.minor - 0.381966011250) < 1e-9)
        #expect(abs((AureanMetrics.Split.major + AureanMetrics.Split.minor) - 1) < 1e-6)
    }
}
