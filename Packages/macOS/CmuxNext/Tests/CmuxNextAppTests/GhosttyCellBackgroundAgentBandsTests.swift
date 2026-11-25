import Foundation
@testable import CmuxNextTerminal
import Testing

/// `appearance.terminalCellBackgrounds = tint` covers every coding-agent TUI, not just Claude Code and Codex:
/// pi's message band and opencode's page are greys too, so the same `background-cells-neutral-fade` that
/// `cellBackgroundLines` loads fades them. The alpha below mirrors ghostty-next's
/// `src/renderer/cell_bg_alpha.zig` (`explicit`) at the pinned GhosttyNextKit; the colours are the ones each
/// program was measured painting (#50576).
@Suite struct GhosttyCellBackgroundAgentBandsTests {
    /// The default dark theme's background ("Apple System Colors").
    private static let theme = rgb(0x1E1E1E)

    private static let claudeBand = rgb(0x373737)
    private static let codexBlock = rgb(0x444444)
    private static let piBand = rgb(0x343541)
    private static let opencodePage = rgb(0x0A0A0A)

    /// ghostty-next `cell_bg_alpha.neutral_chroma`.
    private static let neutralChroma = 0.03

    private static func rgb(_ hex: Int) -> (Double, Double, Double) {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    private static func oklab(_ c: (Double, Double, Double)) -> (Double, Double, Double) {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let (r, g, b) = (linear(c.0), linear(c.1), linear(c.2))
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    /// The alpha Ghostty gives an explicit cell background under `tint` (the fade `cellBackgroundLines` loads).
    private static func tintAlpha(_ bg: (Double, Double, Double), on theme: (Double, Double, Double)) -> Double {
        #expect(GhosttyRuntimeSurfacePolicy.cellBackgroundLines(mode: .tint, configuredOpacity: 1, ownerPaintsBackground: false)
            == ["background-cells-neutral-fade = \(GhosttyRuntimeSurfacePolicy.cellNeutralFade)"])
        let a = oklab(bg), b = oklab(theme)
        guard hypot(a.1 - b.1, a.2 - b.2) < neutralChroma else { return 1 }
        return min(1, abs(a.0 - b.0) / GhosttyRuntimeSurfacePolicy.cellNeutralFade)
    }

    @Test func piBandFadesLikeClaudeAndCodex() {
        let pi = Self.tintAlpha(Self.piBand, on: Self.theme)
        #expect(pi < 0.3)
        #expect(Self.tintAlpha(Self.claudeBand, on: Self.theme) < 0.3)
        #expect(Self.tintAlpha(Self.codexBlock, on: Self.theme) < 0.4)
    }

    @Test func opencodePageFades() {
        #expect(Self.tintAlpha(Self.opencodePage, on: Self.theme) < 0.3)
    }

    @Test func coloredBackgroundsStayOpaque() {
        #expect(Self.tintAlpha(Self.rgb(0x3D1E1E), on: Self.theme) == 1)
        #expect(Self.tintAlpha(Self.rgb(0x1E3A22), on: Self.theme) == 1)
    }
}
