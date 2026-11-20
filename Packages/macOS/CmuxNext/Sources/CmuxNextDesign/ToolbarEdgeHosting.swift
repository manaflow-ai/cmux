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
    /// Whether the omnibar row shows now: false while the person hid it (Toggle Omnibar), in pane fullscreen, or for
    /// a page with no bar. The pane leaves the tab row's divider out over a shown row at its top
    /// (`TabStripView.meetsToolbar`).
    var showsToolbarRow: Bool { get }
}

extension ToolbarEdgeHosting {
    /// The omnibar row shows at the top, right under a tab strip on top: the pane leaves the tab row's divider out
    /// there (`TabStripView.meetsToolbar`), so the tabs and the omnibar read as one surface.
    public var showsToolbarRowAtTop: Bool { toolbarPosition == .top && showsToolbarRow }
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
