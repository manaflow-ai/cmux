public import AppKit
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
    /// The material to blur with, matching the docked ground's.
    public let material: NSVisualEffectView.Material
    /// The material's alpha. Below 1.0 the raw backdrop shows through the
    /// frost, matching the docked pane's see-through glass.
    public let materialOpacity: Double

    /// Creates the backdrop.
    public init(
        cornerRadius: CGFloat,
        material: NSVisualEffectView.Material = .popover,
        materialOpacity: Double = 1.0
    ) {
        self.cornerRadius = cornerRadius
        self.material = material
        self.materialOpacity = materialOpacity
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = material
        view.state = .active
        view.alphaValue = max(0.0, min(1.0, materialOpacity))
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }

    public func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.alphaValue = max(0.0, min(1.0, materialOpacity))
        view.layer?.cornerRadius = cornerRadius
    }
}
