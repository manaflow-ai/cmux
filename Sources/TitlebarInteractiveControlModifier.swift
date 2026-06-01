import SwiftUI

/// Protects an interactive control hosted in (or over) the window titlebar from
/// window-management gestures — window drag, resize drag, and the double-click
/// zoom/minimize action — while leaving the control fully clickable.
///
/// The control stays in its existing SwiftUI host; the modifier only registers
/// the control's region with ``MinimalModeTitlebarControlHitRegionRegistry`` via
/// a transparent `.background(...)` marker (``TitlebarInteractiveControlRegion``).
/// Titlebar drag/double-click routing consults that registry and yields over the
/// region, so the control keeps receiving mouse-downs in place.
struct TitlebarInteractiveControlModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background(TitlebarInteractiveControlRegion())
    }
}

extension View {
    func titlebarInteractiveControl() -> some View {
        modifier(TitlebarInteractiveControlModifier())
    }
}
