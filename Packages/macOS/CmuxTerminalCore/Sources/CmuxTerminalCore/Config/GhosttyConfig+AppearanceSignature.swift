import AppKit
import CmuxFoundation
import Foundation

extension GhosttyConfig {
    /// A stable string fingerprint of every appearance directive that the
    /// embedded ghostty runtime renders from this config, plus whether the host
    /// layer paints the background. Two configs that produce an identical
    /// signature render identically, so the workspace uses signature equality to
    /// decide whether an appearance refresh actually needs to re-apply chrome.
    ///
    /// The field order, alpha inclusion, and float formatting are part of the
    /// fingerprint contract; changing them changes which refreshes are treated
    /// as no-ops.
    public func appearanceSignature(usesHostLayerBackground: Bool) -> String {
        [
            backgroundColor.hexString(includeAlpha: true),
            foregroundColor.hexString(includeAlpha: true),
            cursorColor.hexString(includeAlpha: true),
            cursorTextColor.hexString(includeAlpha: true),
            selectionBackground.hexString(includeAlpha: true),
            selectionForeground.hexString(includeAlpha: true),
            String(format: "%.4f", backgroundOpacity),
            String(describing: backgroundBlur),
            String(format: "%.4f", surfaceTabBarFontSize),
            String(format: "%.4f", unfocusedSplitOpacity),
            unfocusedSplitFill?.hexString(includeAlpha: true) ?? "nil",
            splitDividerColor?.hexString(includeAlpha: true) ?? "nil",
            String(usesHostLayerBackground),
        ].joined(separator: "|")
    }
}
