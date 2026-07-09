public import AppKit

extension NSView {
    /// SwiftUI/AppKit hosting wrappers can appear as the top hit even for empty
    /// titlebar space. Treat those as pass-through so explicit sibling checks decide.
    ///
    /// Interactive titlebar controls are *not* identified here by their hit view.
    /// They register their region with `MinimalModeTitlebarControlHitRegionRegistry`
    /// instead, which `windowDragHandleShouldCaptureHit(_:in:eventType:eventWindow:)`
    /// consults (via `isMinimalModeTitlebarControlHit`) before this sibling walk runs,
    /// so a registered control already makes the drag handle yield.
    ///
    /// Pure value predicate, faithful lift of the app-side
    /// `windowDragHandleShouldTreatTopHitAsPassiveHost` free function.
    public var isWindowDragHandlePassiveHost: Bool {
        let className = String(describing: type(of: self))
        if className.contains("HostContainerView")
            || className.contains("AppKitWindowHostingView")
            || className.contains("NSHostingView") {
            return true
        }
        if let window, self === window.contentView {
            return true
        }
        return false
    }
}
