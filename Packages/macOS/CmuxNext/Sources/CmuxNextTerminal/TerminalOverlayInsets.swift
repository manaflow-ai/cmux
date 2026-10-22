import AppKit

/// The terminal host's overlays (status banner, "Sized for" chip) are framed in
/// `TerminalHostView.layout()`, not by Auto Layout, so AppKit turns their autoresizing mask into
/// required width and height constraints. Hidden, they sit at a 0x0 frame, and required insets
/// inside them conflicted with it on every mount: 4 "Unable to simultaneously satisfy
/// constraints" faults per terminal (perf100). Just below required, the insets give way silently
/// at 0x0 and still size the overlay: `fittingSize` compresses only at fitting priority.
enum TerminalOverlayInsets {
    static let priority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.required.rawValue - 1)

    static func breakable(_ constraints: [NSLayoutConstraint]) -> [NSLayoutConstraint] {
        for constraint in constraints { constraint.priority = priority }
        return constraints
    }
}
