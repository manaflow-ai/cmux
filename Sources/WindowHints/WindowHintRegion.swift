import AppKit
import SwiftUI

/// Names a SwiftUI control for hint mode (``WindowHintTargets``): in process,
/// a SwiftUI host shows its controls only as AXUnknown elements, so the
/// control carries a transparent background view that the walk finds among
/// the window's subviews, at the control's frame. Clicks pass through it.
struct WindowHintRegion: NSViewRepresentable {
    let title: String
    let isEnabled: Bool

    final class MarkerView: NSView {
        var title = ""
        var isEnabled = true

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
    }

    func makeNSView(context: Context) -> MarkerView {
        MarkerView(frame: .zero)
    }

    func updateNSView(_ view: MarkerView, context: Context) {
        view.title = title
        view.isEnabled = isEnabled
    }
}

extension View {
    /// Labels this control in hint mode, named `title` (its accessibility
    /// label); a disabled control gets no label.
    func windowHintTarget(_ title: String, isEnabled: Bool = true) -> some View {
        background(WindowHintRegion(title: title, isEnabled: isEnabled))
    }

    /// The control's accessibility label, which also names it in hint mode.
    func hintableAccessibilityLabel(_ title: String, isEnabled: Bool = true) -> some View {
        accessibilityLabel(title).windowHintTarget(title, isEnabled: isEnabled)
    }
}
