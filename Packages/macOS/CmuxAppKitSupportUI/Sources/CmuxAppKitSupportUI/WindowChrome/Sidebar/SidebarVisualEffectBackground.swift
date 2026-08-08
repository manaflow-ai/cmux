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

    init(
        material: NSVisualEffectView.Material = .hudWindow,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        state: NSVisualEffectView.State = .active,
        opacity: Double = 1.0,
        tintColor: NSColor? = nil,
        cornerRadius: CGFloat = 0,
        preferLiquidGlass: Bool = false
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.state = state
        self.opacity = opacity
        self.tintColor = tintColor
        self.cornerRadius = cornerRadius
        self.preferLiquidGlass = preferLiquidGlass
    }

    static var liquidGlassAvailable: Bool {
        if #available(macOS 26.0, *) {
            return true
        }
        return false
    }

    func makeNSView(context: Context) -> NSView {
        if preferLiquidGlass {
            if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView(frame: .zero)
                glass.style = .regular
                glass.autoresizingMask = [.width, .height]
                return glass
            }
        }

        let view = NSVisualEffectView()
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .onSetNeedsDisplay
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let clampedOpacity = max(0.0, min(1.0, opacity))
        if #available(macOS 26.0, *), let glass = nsView as? NSGlassEffectView {
            glass.style = .regular
            glass.tintColor = tintColor
            glass.cornerRadius = cornerRadius
            glass.alphaValue = clampedOpacity
            // `cornerRadius` is a native glass input. Layer clipping would
            // flatten the lens and clip its edge illumination.
            glass.layer?.masksToBounds = false
            glass.autoresizingMask = [.width, .height]
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
