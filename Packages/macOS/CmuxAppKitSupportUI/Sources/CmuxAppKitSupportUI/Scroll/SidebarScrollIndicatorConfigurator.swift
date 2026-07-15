public import AppKit
import ObjectiveC

extension NSScrollView {
  /// Configures the native vertical scroller as a cmux-controlled overlay
  /// that remains interactive while visible.
  @MainActor
  public func applySidebarScrollIndicatorConfiguration() {
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
