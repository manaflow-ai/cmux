public import AppKit
public import CmuxNextDesignTokens

/// A pane content view with an omnibar row it can put at its top or bottom
/// edge (`browser.toolbarPosition`): the browser chrome and a page tab with a
/// native bar (the Markdown viewer). The pane sets ``toolbarPosition`` from the
/// setting; views inside the row read ``NSView/toolbarOpensUpward`` to open
/// their popups away from the window's edge.
@MainActor
public protocol ToolbarEdgeHosting: AnyObject {
    /// The edge the row sits on; setting it moves the row.
    var toolbarPosition: ToolbarPosition { get set }
}

extension NSView {
    /// Whether popups opened from this view open upward: it sits in the
    /// omnibar row of a ``ToolbarEdgeHosting`` view whose row is at the bottom.
    public var toolbarOpensUpward: Bool {
        var view: NSView? = self
        while let current = view {
            if let host = current as? any ToolbarEdgeHosting { return host.toolbarPosition == .bottom }
            view = current.superview
        }
        return false
    }

    /// The side a popup opened from this view prefers (``toolbarOpensUpward``): above in a
    /// bottom omnibar row, else below.
    public var toolbarPopupSide: PopupPlacement.Side { toolbarOpensUpward ? .above : .below }
}
