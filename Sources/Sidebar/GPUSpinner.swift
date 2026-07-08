import AppKit
import SwiftUI

/// A GPU-driven indeterminate spinner: the only animated property is the layer
/// transform (render-server interpolated, zero per-frame CPU), and the
/// animation is removed while off-window, occluded, or under Reduce Motion.
struct GPUSpinner: NSViewRepresentable {
    let style: GPUSpinnerStyle
    let color: NSColor

    func makeNSView(context: Context) -> GPUSpinnerNSView {
        let view = GPUSpinnerNSView(frame: .zero)
        view.style = style
        view.color = color
        return view
    }

    func updateNSView(_ view: GPUSpinnerNSView, context: Context) {
        view.style = style
        view.color = color
    }
}
