import AppKit
public import SwiftUI

/// Behind-window blur for the floating card.
///
/// The card lives in its own borderless child window, which is exactly what
/// makes real glass possible: an NSVisualEffectView blending behind-window
/// samples whatever is under the panel, which here is the live terminal.
/// SwiftUI's `Material` cannot do this job in the panel; it blurs only
/// content inside its own window, and the panel's own backdrop is empty.
public struct SidebarPeekGlassBackdrop: NSViewRepresentable {
    /// Corner radius matching the card shape.
    public let cornerRadius: CGFloat

    /// Creates the backdrop.
    public init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .popover
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }

    public func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.layer?.cornerRadius = cornerRadius
    }
}
