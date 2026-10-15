public import AppKit

extension ColorTransition {
    /// The window backdrop's colors as the render server shows them now, mid-blend included
    /// (`debug.themes` `backdrop`): `sheet` (an opaque window's fill) and `tint` (the theme tint
    /// over a material) as `#RRGGBBAA` in sRGB, empty when not painted; `blending` is "true" while
    /// either runs a color transition; `seconds` is the transition in effect now.
    @MainActor
    public static func presentedBackdrop(of window: NSWindow) -> [String: String] {
        guard let material = window.contentView.flatMap(materialView(in:)) else { return [:] }
        let sheet = material.superview?.layer
        let tint = material.shownTintLayer
        func shown(_ layer: CALayer?) -> String {
            let color = layer?.presentation()?.backgroundColor ?? layer?.backgroundColor
            guard let rgb = rgb(color) else { return "" }
            func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
            return String(format: "#%02X%02X%02X%02X", byte(rgb.red), byte(rgb.green), byte(rgb.blue), byte(rgb.alpha))
        }
        let key = layerKey
        let blending = sheet?.animation(forKey: key) != nil || tint?.animation(forKey: key) != nil
        return ["sheet": shown(sheet), "tint": shown(tint), "blending": blending ? "true" : "false",
                "seconds": String(current.seconds)]
    }

    @MainActor
    private static func materialView(in view: NSView) -> WindowMaterialView? {
        if let found = view as? WindowMaterialView { return found }
        for subview in view.subviews { if let found = materialView(in: subview) { return found } }
        return nil
    }
}
