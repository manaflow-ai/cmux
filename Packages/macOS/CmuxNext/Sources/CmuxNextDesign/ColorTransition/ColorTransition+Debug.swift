public import AppKit
public import CmuxNextDesignTokens

extension ColorTransition {
    /// The window backdrop's colors as the render server shows them now, mid-blend included
    /// (`debug.themes` `backdrop`): `sheet` (an opaque window's fill) and `tint` (the theme tint
    /// over a material) as `#RRGGBBAA` in sRGB, empty when not painted; `glassTint` (Liquid
    /// Glass's own tint), `glassOverlay` and `glassOverlayOpacity` (the old tint fading out over
    /// it during a blend, empty otherwise); `blending` is "true" while any of them runs a color
    /// transition; `seconds` is the transition in effect now.
    @MainActor
    public static func presentedBackdrop(of window: NSWindow) -> [String: String] {
        guard let material = window.contentView.flatMap(materialView(in:)) else { return [:] }
        let sheet = material.superview?.layer
        let tint = material.shownTintLayer
        func hex(_ rgb: ThemeRGB) -> String {
            func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
            return String(format: "#%02X%02X%02X%02X", byte(rgb.red), byte(rgb.green), byte(rgb.blue), byte(rgb.alpha))
        }
        func shown(_ layer: CALayer?) -> String {
            let color = layer?.presentation()?.backgroundColor ?? layer?.backgroundColor
            return rgb(color).map(hex) ?? ""
        }
        let key = layerKey
        let overlay = material.shownGlassBlendLayer
        let blending = sheet?.animation(forKey: key) != nil || tint?.animation(forKey: key) != nil || overlay != nil
        // Liquid Glass: its tint (the end color) and the old tint's overlay with its opacity on screen.
        let glass = rgb(material.glassTintColor).map(hex) ?? ""
        // A blend added in this run loop turn is not on screen yet: its first frame shows its first
        // keyframe (the old tint, opaque), not the presentation layer the last commit left.
        let pending = overlay?.animation(forKey: GlassTintBlend.key).map { $0.beginTime == 0 } ?? false
        let overlayOpacity = overlay.map { String(format: "%.3f", pending ? 1 : ($0.presentation() ?? $0).opacity) } ?? ""
        let overlayColor = pending ? rgb(overlay?.backgroundColor).map(hex) ?? "" : shown(overlay)
        return ["sheet": shown(sheet), "tint": shown(tint), "glassTint": glass, "glassOverlay": overlayColor,
                "glassOverlayOpacity": overlayOpacity, "blending": blending ? "true" : "false",
                "seconds": String(current.seconds)]
    }

    @MainActor
    private static func materialView(in view: NSView) -> WindowMaterialView? {
        if let found = view as? WindowMaterialView { return found }
        for subview in view.subviews { if let found = materialView(in: subview) { return found } }
        return nil
    }
}
