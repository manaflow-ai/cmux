import AppKit

/// Scene prop parsing shared by the AppKit renderer (`AppJSON.sceneColor`).
nonisolated enum AppSceneStyle {
    /// `#RRGGBB` or `#RRGGBBAA` in sRGB; nil for anything else.
    static func hexColor(_ text: String) -> NSColor? {
        guard text.hasPrefix("#"), text.count == 7 || text.count == 9, let value = UInt64(text.dropFirst(), radix: 16) else { return nil }
        let hasAlpha = text.count == 9
        let r = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(value & 0xFF) / 255 : 1
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
