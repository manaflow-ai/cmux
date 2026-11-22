public import AppKit

// The footer's accessory slots. It never shows Back (Lawrence 2026-10-09):
// leaving a page is the page's own job or the titlebar's Go Back
// (SidebarFooterHasNoBackTests).
extension SidebarView {
    /// Installs (or removes, with nil) the view in a footer slot.
    public func setAccessory(_ view: NSView?, for slot: SidebarAccessorySlot) {
        accessories[slot]?.removeFromSuperview()
        accessories[slot] = view
        if let view {
            view.translatesAutoresizingMaskIntoConstraints = true
            footer.addSubview(view)
        }
        needsLayout = true
    }
}
