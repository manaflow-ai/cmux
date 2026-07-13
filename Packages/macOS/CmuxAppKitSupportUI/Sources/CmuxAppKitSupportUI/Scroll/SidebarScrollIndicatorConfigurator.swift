public import AppKit

extension NSScrollView {
    /// Disables AppKit's preference-controlled sidebar scrollers and attaches
    /// the cmux-owned user-scroll indicator.
    @MainActor
    public func applySidebarScrollIndicatorConfiguration() {
        if hasHorizontalScroller {
            hasHorizontalScroller = false
        }
        if hasVerticalScroller {
            hasVerticalScroller = false
        }
        SidebarScrollIndicatorVisibilityControllers.attach(to: self)
    }
}
