import AppKit
import SwiftUI

/// Wrapper view that tries `NSGlassEffectView` when requested and falls back to
/// `NSVisualEffectView`.
struct SidebarVisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let state: NSVisualEffectView.State
    let opacity: Double
    let tintColor: NSColor?
    let cornerRadius: CGFloat
    let preferLiquidGlass: Bool
    let appearanceName: NSAppearance.Name?

    init(
        material: NSVisualEffectView.Material = .hudWindow,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        state: NSVisualEffectView.State = .active,
        opacity: Double = 1.0,
        tintColor: NSColor? = nil,
        cornerRadius: CGFloat = 0,
        preferLiquidGlass: Bool = false,
        appearanceName: NSAppearance.Name? = nil
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.state = state
        self.opacity = opacity
        self.tintColor = tintColor
        self.cornerRadius = cornerRadius
        self.preferLiquidGlass = preferLiquidGlass
        self.appearanceName = appearanceName
    }

    /// Resolved appearance to force on the effect view, or `nil` to inherit.
    private var resolvedAppearance: NSAppearance? {
        appearanceName.flatMap(NSAppearance.init(named:))
    }

    static var liquidGlassAvailable: Bool {
        NSClassFromString("NSGlassEffectView") != nil
    }

    func makeNSView(context: Context) -> NSView {
        if preferLiquidGlass, let glassClass = NSClassFromString("NSGlassEffectView") as? NSView.Type {
            let glass = glassClass.init(frame: .zero)
            glass.autoresizingMask = [.width, .height]
            glass.wantsLayer = true
            glass.appearance = resolvedAppearance
            return glass
        }

        let view = NSVisualEffectView()
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .onSetNeedsDisplay
        view.appearance = resolvedAppearance
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let clampedOpacity = max(0.0, min(1.0, opacity))
        // Force the effect view's appearance so the native material renders in
        // the app color scheme even when the host window's NSAppearance differs.
        nsView.appearance = resolvedAppearance
        if nsView.className == "NSGlassEffectView" {
            nsView.alphaValue = clampedOpacity
            nsView.layer?.cornerRadius = cornerRadius
            nsView.layer?.masksToBounds = cornerRadius > 0

            let selector = NSSelectorFromString("setTintColor:")
            if nsView.responds(to: selector) {
                nsView.perform(selector, with: tintColor)
            }
        } else if let visualEffect = nsView as? NSVisualEffectView {
            visualEffect.material = material
            visualEffect.blendingMode = blendingMode
            visualEffect.state = state
            visualEffect.alphaValue = clampedOpacity
            visualEffect.layer?.cornerRadius = cornerRadius
            visualEffect.layer?.masksToBounds = cornerRadius > 0
            visualEffect.needsDisplay = true
        }
    }
}
