public import AppKit
public import GhosttyKit

extension NSColor {
    /// Builds an opaque `NSColor` from a libghostty `color_change` action's
    /// 8-bit RGB components.
    ///
    /// Byte-faithful home of the legacy `GhosttyApp.color(from:)` mapper: each
    /// component is divided by 255 and alpha is fixed at 1.0, matching the
    /// app- and surface-scoped OSC color-change handlers exactly.
    public convenience init(ghosttyColorChange change: ghostty_action_color_change_s) {
        self.init(
            red: CGFloat(change.r) / 255,
            green: CGFloat(change.g) / 255,
            blue: CGFloat(change.b) / 255,
            alpha: 1.0
        )
    }
}
