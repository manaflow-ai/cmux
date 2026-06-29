public import AppKit

/// Native glass tint and style for a window backdrop plan.
public struct WindowBackdropGlassPlan {
    /// Tint applied to the glass hierarchy, or `nil` to leave native glass untinted.
    public let tintColor: NSColor?

    /// Native glass style.
    public let style: WindowGlassEffectStyle

    /// Creates a glass plan.
    public init(tintColor: NSColor?, style: WindowGlassEffectStyle) {
        self.tintColor = tintColor
        self.style = style
    }
}
