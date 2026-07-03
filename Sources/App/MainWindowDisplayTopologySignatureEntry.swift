import CoreGraphics

/// One display's frame arrangement contribution to the main-window rescue gate.
///
/// The rest of `visibleFrame` is deliberately omitted: Dock and side-inset
/// resizes cannot strand a titlebar and must not read as topology changes. The
/// top inset is included because a menu bar appearing on (or moving to) a
/// display shrinks the visible area from the top and can newly cover a
/// flush-top window's drag band. Display IDs are deliberately omitted because
/// dock/KVM/Sidecar wake paths can re-enumerate the same physical arrangement
/// with new `NSScreenNumber` values.
struct MainWindowDisplayTopologySignatureEntry: Equatable {
    let frame: CGRect
    let topInset: CGFloat
}
