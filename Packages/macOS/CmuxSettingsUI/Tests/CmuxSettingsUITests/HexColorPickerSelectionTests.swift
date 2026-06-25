import AppKit
import SwiftUI
import Testing
@testable import CmuxSettingsUI

@MainActor
@Suite
struct HexColorPickerSelectionTests {
    @Test func sRGBHexRoundTripLosesHueNearBlack() throws {
        let sourceHue: CGFloat = 0.72
        let source = nsColor(hue: sourceHue, brightness: 0.001)
        let sourceColor = Color(nsColor: source)
        let hex = sourceColor.cmuxHexString

        #expect(hex == "#000000")

        let roundTrippedColor = try #require(Color(cmuxHex: hex))
        let roundTrippedHue = try hue(of: roundTrippedColor)

        #expect(hueDistance(sourceHue, roundTrippedHue) > 0.2)
    }

    @Test func hexBackedPickerBindingKeepsLiveHueWhenPersistingDimmedColor() throws {
        let sourceHue: CGFloat = 0.72
        var storedHex = Color(nsColor: nsColor(hue: sourceHue, brightness: 1)).cmuxHexString

        func get() -> Color {
            Color(cmuxHex: storedHex) ?? Color(nsColor: .systemBlue)
        }

        func set(_ newColor: Color) {
            storedHex = newColor.cmuxHexString
        }

        let dimmedColor = Color(nsColor: nsColor(hue: sourceHue, brightness: 0.001))
        set(dimmedColor)

        let liveHue = try hue(of: get())
        #expect(hueDistance(sourceHue, liveHue) < 0.01)
    }

    private func nsColor(hue: CGFloat, brightness: CGFloat) -> NSColor {
        NSColor(calibratedHue: hue, saturation: 1, brightness: brightness, alpha: 1)
    }

    private func hue(of color: Color) throws -> CGFloat {
        let nsColor = NSColor(color)
        let rgb = try #require(nsColor.usingColorSpace(.sRGB))
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return hue
    }

    private func hueDistance(_ lhs: CGFloat, _ rhs: CGFloat) -> CGFloat {
        let distance = abs(lhs - rhs)
        return min(distance, 1 - distance)
    }
}
