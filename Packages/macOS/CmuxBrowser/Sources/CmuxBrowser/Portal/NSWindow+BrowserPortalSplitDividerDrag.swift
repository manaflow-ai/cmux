import AppKit
internal import ObjectiveC

extension NSWindow {
    private static let browserPortalInteractiveSplitDividerDragKey = malloc(1)!

    /// Whether an interactive split-divider drag is currently in progress for
    /// this window's browser portal.
    ///
    /// Backed by an objc associated object so the flag rides on the window
    /// itself. The getter is self-clearing: it returns `false` (and resets the
    /// stored flag) the moment the primary mouse button is no longer pressed, so
    /// a drag that ended without a corresponding split-resize notification cannot
    /// leave the flag stuck on. Used by ``BrowserPortalSplitResizeDecision`` to
    /// suppress the portal-wide external-geometry sync while the user drags an
    /// app split divider (whose anchors already emit coalesced geometry
    /// callbacks).
    var browserPortalHasInteractiveSplitDividerDrag: Bool {
        get {
            let isActive =
                (objc_getAssociatedObject(self, Self.browserPortalInteractiveSplitDividerDragKey) as? NSNumber)?
                    .boolValue ?? false
            guard isActive else { return false }
            guard (NSEvent.pressedMouseButtons & 1) != 0 else {
                objc_setAssociatedObject(
                    self,
                    Self.browserPortalInteractiveSplitDividerDragKey,
                    NSNumber(value: false),
                    .OBJC_ASSOCIATION_RETAIN_NONATOMIC
                )
                return false
            }
            return true
        }
        set {
            objc_setAssociatedObject(
                self,
                Self.browserPortalInteractiveSplitDividerDragKey,
                NSNumber(value: newValue),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }
}
