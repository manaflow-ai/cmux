import AppKit
import CmuxDesignSystem
import Testing

@Suite
struct WorkspaceColorHexTests {
    @Test
    func normalizesSixDigitHexValues() throws {
        #expect(WorkspaceColorHex("#abc123")?.rawValue == "#ABC123")
        #expect(WorkspaceColorHex("  aBcDeF ")?.rawValue == "#ABCDEF")
        #expect(WorkspaceColorHex("#1234") == nil)
        #expect(WorkspaceColorHex("#GG1234") == nil)
    }

    @Test
    func rendersSRGBColor() throws {
        let color = try #require(WorkspaceColorHex("#336699")?.nsColor.usingColorSpace(.sRGB))

        #expect(Int((color.redComponent * 255).rounded()) == 51)
        #expect(Int((color.greenComponent * 255).rounded()) == 102)
        #expect(Int((color.blueComponent * 255).rounded()) == 153)
    }

    @Test
    func boostsDarkAppearanceBrightness() throws {
        let color = try #require(WorkspaceColorHex("#283593"))
        let light = try #require(color.displayNSColor(colorScheme: .light).usingColorSpace(.sRGB))
        let dark = try #require(color.displayNSColor(colorScheme: .dark).usingColorSpace(.sRGB))

        #expect(dark.brightnessComponent > light.brightnessComponent)
    }
}
