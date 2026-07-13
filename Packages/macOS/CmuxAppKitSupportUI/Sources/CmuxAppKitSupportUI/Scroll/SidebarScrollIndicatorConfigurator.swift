public import AppKit
import ObjectiveC

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
        if let controller = objc_getAssociatedObject(
            self,
            &SidebarScrollIndicatorVisibilityController.associationKey
        ) as? SidebarScrollIndicatorVisibilityController {
            controller.synchronizeIndicator()
            return
        }

        let controller = SidebarScrollIndicatorVisibilityController(scrollView: self)
        objc_setAssociatedObject(
            self,
            &SidebarScrollIndicatorVisibilityController.associationKey,
            controller,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
}
