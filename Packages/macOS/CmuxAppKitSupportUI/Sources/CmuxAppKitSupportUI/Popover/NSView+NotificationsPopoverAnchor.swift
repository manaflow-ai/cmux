public import AppKit

extension NSView {
    /// Whether this view is eligible to anchor the notifications popover: it and every
    /// ancestor must be visible (not hidden and with a positive alpha). Walks the
    /// superview chain to the root and returns `false` on the first hidden or transparent
    /// view encountered.
    @MainActor
    public var isVisibleAsNotificationsPopoverAnchor: Bool {
        var current: NSView? = self
        while let candidate = current {
            if candidate.isHidden || candidate.alphaValue <= 0 {
                return false
            }
            current = candidate.superview
        }
        return true
    }

    /// Chooses the anchor the notifications popover should attach to.
    ///
    /// Prefers `buttonAnchor` when it lives in a window, shares that window with
    /// `fallbackAnchor` (or `fallbackAnchor` has no window), has a non-empty bounds, and is
    /// a visible popover anchor. Otherwise returns `fallbackAnchor`.
    @MainActor
    public static func preferredNotificationsPopoverAnchor(
        buttonAnchor: NSView?,
        fallbackAnchor: NSView?
    ) -> NSView? {
        let fallbackWindow = fallbackAnchor?.window
        guard let buttonAnchor,
              let buttonWindow = buttonAnchor.window,
              fallbackWindow == nil || buttonWindow === fallbackWindow,
              !buttonAnchor.bounds.isEmpty,
              buttonAnchor.isVisibleAsNotificationsPopoverAnchor else {
            return fallbackAnchor
        }
        return buttonAnchor
    }
}
