public import AppKit

extension NSColor {
    /// Returns the receiver as an uppercase `#RRGGBB` (or `#RRGGBBAA`) hex string,
    /// converting to the sRGB color space first.
    /// - Parameter includeAlpha: When `true`, appends the alpha byte as `#RRGGBBAA`.
    public func hexString(includeAlpha: Bool = false) -> String {
        let color = usingColorSpace(.sRGB) ?? self
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let redByte = min(255, max(0, Int(red * 255)))
        let greenByte = min(255, max(0, Int(green * 255)))
        let blueByte = min(255, max(0, Int(blue * 255)))
        if includeAlpha {
            let alphaByte = min(255, max(0, Int(alpha * 255)))
            return String(format: "#%02X%02X%02X%02X", redByte, greenByte, blueByte, alphaByte)
        }
        return String(format: "#%02X%02X%02X", redByte, greenByte, blueByte)
    }
}
