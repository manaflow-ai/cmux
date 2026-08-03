import AppKit
import Testing
@testable import CmuxSettingsUI

@MainActor
@Suite
struct HexColorPickerSelectionTests {
    @Test func sRGBHexRoundTripLosesHueNearBlack() throws {
        let sourceHue: CGFloat = 0.72
        let source = nsColor(hue: sourceHue, brightness: 0.001)
        let sourceColor = source
        let hex = sourceColor.cmuxHexString

        #expect(hex == "#000000")

        let roundTrippedColor = try #require(NSColor(cmuxHex: hex))
        let roundTrippedHue = try hue(of: roundTrippedColor)

        #expect(hueDistance(sourceHue, roundTrippedHue) > 0.2)
    }

    @Test func stateBackedPickerBindingKeepsLiveHueWhenPersistingDimmedColor() throws {
        let sourceHue: CGFloat = 0.72
        let initialHex = nsColor(hue: sourceHue, brightness: 1).cmuxHexString
        var selection = HexColorPickerSelection(
            state: HexColorPickerReconcileState(storedHex: initialHex, revision: 0),
            fallback: .systemBlue
        )

        let dimmedColor = nsColor(hue: sourceHue, brightness: 0.001)
        let storedHex = selection.applyPickerSelection(dimmedColor)

        #expect(storedHex == "#000000")

        selection.reconcile(state: HexColorPickerReconcileState(storedHex: storedHex, revision: 1))
        let liveHue = try hue(of: selection.color)
        #expect(hueDistance(sourceHue, liveHue) < 0.01)
    }

    @Test func storedHexChangeReconcilesLiveColorFromExternalUpdate() throws {
        let fallback = try #require(NSColor(cmuxHex: "#123456"))
        var selection = HexColorPickerSelection(
            state: HexColorPickerReconcileState(storedHex: "#FF0000", revision: 0),
            fallback: fallback
        )
        _ = selection.applyPickerSelection(nsColor(hue: 0.72, brightness: 0.001))

        selection.reconcile(state: HexColorPickerReconcileState(storedHex: "#00FF00", revision: 1))
        #expect(selection.color.cmuxHexString == "#00FF00")

        selection.reconcile(state: HexColorPickerReconcileState(storedHex: "", revision: 2))
        #expect(selection.color.cmuxHexString == "#123456")
    }

    @Test func externalStoredHexMatchingLiveQuantizedHexRebuildsColor() throws {
        let sourceHue: CGFloat = 0.72
        let initialHex = nsColor(hue: sourceHue, brightness: 1).cmuxHexString
        var selection = HexColorPickerSelection(
            state: HexColorPickerReconcileState(storedHex: initialHex, revision: 0),
            fallback: .systemBlue
        )
        let dimmedColor = nsColor(hue: sourceHue, brightness: 0.001)

        let storedHex = selection.applyPickerSelection(dimmedColor)
        selection.reconcile(state: HexColorPickerReconcileState(storedHex: storedHex, revision: 1))
        #expect(hueDistance(sourceHue, try hue(of: selection.color)) < 0.01)

        selection.reconcile(state: HexColorPickerReconcileState(storedHex: storedHex, revision: 2))
        #expect(hueDistance(sourceHue, try hue(of: selection.color)) > 0.2)
    }

    @Test func sameHexExternalReconcileBeforeLocalEchoRebuildsColor() throws {
        let sourceHue: CGFloat = 0.72
        let initialHex = nsColor(hue: sourceHue, brightness: 1).cmuxHexString
        var selection = HexColorPickerSelection(
            state: HexColorPickerReconcileState(storedHex: initialHex, revision: 0),
            fallback: .systemBlue
        )
        let dimmedColor = nsColor(hue: sourceHue, brightness: 0.001)

        let storedHex = selection.applyPickerSelection(dimmedColor)

        #expect(storedHex == "#000000")

        selection.reconcile(state: HexColorPickerReconcileState(storedHex: storedHex, revision: 2))
        #expect(hueDistance(sourceHue, try hue(of: selection.color)) > 0.2)
    }

    private func nsColor(hue: CGFloat, brightness: CGFloat) -> NSColor {
        NSColor(calibratedHue: hue, saturation: 1, brightness: brightness, alpha: 1)
    }

    private func hue(of color: NSColor) throws -> CGFloat {
        let rgb = try #require(color.usingColorSpace(.sRGB))
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
