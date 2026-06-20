#if canImport(AppKit)

internal import AppKit
internal import Bonsplit

/// One backdrop-tuning sample shown as a card in ``TabBarBackdropLabView``.
///
/// Each variant pairs a `Bonsplit` split-button backdrop effect with the resolved
/// chrome/pane/border colors and opacity for a single preview tile. The view
/// builds the full variant list from the live ``TabBarBackdropLabInputs`` snapshot
/// plus the current slider state.
struct TabBarBackdropLabVariant: Identifiable {
    let id: String
    let title: String
    let detail: String
    let effect: BonsplitConfiguration.Appearance.SplitButtonBackdropEffect
    let chromeHex: String
    let tabBarHex: String
    let splitButtonBackdropHex: String
    let paneHex: String
    let borderHex: String
    let terminalColor: NSColor
    let surfaceColor: NSColor
    let separatorColor: NSColor
    let opacity: CGFloat

    /// A stable identity that changes whenever any rendered property changes, used
    /// to force the `Bonsplit` controller to re-apply its configuration on edit.
    var renderIdentity: String {
        let separatorFadeWidth = effect.separatorFadeWidth.map { String(format: "%.1f", $0) } ?? "nil"
        return "\(id)-\(chromeHex)-\(tabBarHex)-\(splitButtonBackdropHex)-\(paneHex)-\(borderHex)-\(String(format: "%.3f", opacity))-\(String(format: "%.1f", effect.fadeWidth))-\(String(format: "%.1f", effect.contentFadeWidth))-\(String(format: "%.1f", effect.solidWidth))-\(String(format: "%.1f", effect.solidSurfaceWidthAdjustment))-\(separatorFadeWidth)-\(String(format: "%.2f", effect.fadeRampStartFraction))-\(String(format: "%.2f", effect.leadingOpacity))-\(String(format: "%.2f", effect.trailingOpacity))-\(String(format: "%.2f", effect.contentOcclusionFraction))-\(effect.masksTabContent ? 1 : 0)"
    }
}

#endif
