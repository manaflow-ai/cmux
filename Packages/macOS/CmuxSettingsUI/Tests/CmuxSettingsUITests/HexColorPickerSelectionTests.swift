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

    @Test func stateBackedPickerBindingKeepsLiveHueWhenPersistingDimmedColor() throws {
        let sourceHue: CGFloat = 0.72
        let initialHex = Color(nsColor: nsColor(hue: sourceHue, brightness: 1)).cmuxHexString
        var selection = HexColorPickerSelection(storedHex: initialHex, fallback: Color(nsColor: .systemBlue))

        let dimmedColor = Color(nsColor: nsColor(hue: sourceHue, brightness: 0.001))
        let storedHex = selection.applyPickerSelection(dimmedColor)

        #expect(storedHex == "#000000")

        selection.reconcile(storedHex: storedHex)
        let liveHue = try hue(of: selection.color)
        #expect(hueDistance(sourceHue, liveHue) < 0.01)
    }

    @Test func storedHexChangeReconcilesLiveColorFromExternalUpdate() throws {
        let fallback = try #require(Color(cmuxHex: "#123456"))
        var selection = HexColorPickerSelection(storedHex: "#FF0000", fallback: fallback)
        _ = selection.applyPickerSelection(Color(nsColor: nsColor(hue: 0.72, brightness: 0.001)))

        selection.reconcile(storedHex: "#00FF00")
        #expect(selection.color.cmuxHexString == "#00FF00")

        selection.reconcile(storedHex: "")
        #expect(selection.color.cmuxHexString == "#123456")
    }

    @Test func externalStoredHexMatchingLiveQuantizedHexRebuildsColor() throws {
        let sourceHue: CGFloat = 0.72
        let initialHex = Color(nsColor: nsColor(hue: sourceHue, brightness: 1)).cmuxHexString
        var selection = HexColorPickerSelection(storedHex: initialHex, fallback: Color(nsColor: .systemBlue))
        let dimmedColor = Color(nsColor: nsColor(hue: sourceHue, brightness: 0.001))

        let storedHex = selection.applyPickerSelection(dimmedColor)
        selection.reconcile(storedHex: storedHex)
        #expect(hueDistance(sourceHue, try hue(of: selection.color)) < 0.01)

        selection.reconcile(storedHex: storedHex)
        #expect(hueDistance(sourceHue, try hue(of: selection.color)) > 0.2)
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
