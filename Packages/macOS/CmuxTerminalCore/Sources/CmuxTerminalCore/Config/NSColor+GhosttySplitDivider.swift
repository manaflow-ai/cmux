public import AppKit
public import CmuxFoundation

extension NSColor {
    /// The high-contrast split-divider color cmux derives for this terminal background.
    public var ghosttyDefaultSplitDividerColor: NSColor {
        let color = usingColorSpace(.sRGB) ?? self
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: nil)

        let isLightBackground = color.isLightColor
        let mixAmount: CGFloat = isLightBackground ? 0.22 : 0.30
        let targetComponent: CGFloat = isLightBackground ? 0 : 1
        return NSColor(
            srgbRed: red + (targetComponent - red) * mixAmount,
            green: green + (targetComponent - green) * mixAmount,
            blue: blue + (targetComponent - blue) * mixAmount,
            alpha: 1
        )
    }
}
