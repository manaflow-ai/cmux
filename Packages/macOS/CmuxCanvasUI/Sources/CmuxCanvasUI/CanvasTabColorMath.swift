import AppKit

/// Tab color derivation ported from bonsplit's TabBarColors so canvas tabs
/// read like split-pane tabs: active/hover tab fills are the bar background
/// nudged lighter (dark themes) or darker (light themes), text uses the
/// system label colors, matching bonsplit's treatment without importing its
/// internal styling.
extension NSColor {
    /// Perceived-luminance test (Rec. 601), matching bonsplit's light check.
    var cmuxCanvasIsLight: Bool {
        guard let rgb = usingColorSpace(.sRGB) else { return false }
        let luma = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luma > 0.5
    }

    /// Lightens toward white by `amount` (0...1).
    func cmuxCanvasLighten(by amount: CGFloat) -> NSColor {
        blended(withFraction: amount, of: .white) ?? self
    }

    /// Darkens toward black by `amount` (0...1).
    func cmuxCanvasDarken(by amount: CGFloat) -> NSColor {
        blended(withFraction: amount, of: .black) ?? self
    }

    /// The active (selected) tab fill for a bar of this background color.
    var cmuxCanvasActiveTabFill: NSColor {
        if cmuxCanvasHexString == "#13141C" {
            return NSColor(srgbRed: 25.0 / 255.0, green: 26.0 / 255.0, blue: 35.0 / 255.0, alpha: 1)
        }
        if cmuxCanvasHexString == "#F3F3F4" {
            return NSColor(srgbRed: 252.0 / 255.0, green: 252.0 / 255.0, blue: 253.0 / 255.0, alpha: 1)
        }
        return cmuxCanvasIsLight ? cmuxCanvasDarken(by: 0.065) : cmuxCanvasLighten(by: 0.12)
    }

    /// The hovered (unselected) tab fill for a bar of this background color.
    var cmuxCanvasHoverTabFill: NSColor {
        let adjusted = cmuxCanvasIsLight ? cmuxCanvasDarken(by: 0.03) : cmuxCanvasLighten(by: 0.07)
        return adjusted.withAlphaComponent(0.78)
    }

    private var cmuxCanvasHexString: String? {
        guard let rgb = usingColorSpace(.sRGB) else { return nil }
        let red = Int((rgb.redComponent * 255).rounded())
        let green = Int((rgb.greenComponent * 255).rounded())
        let blue = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
