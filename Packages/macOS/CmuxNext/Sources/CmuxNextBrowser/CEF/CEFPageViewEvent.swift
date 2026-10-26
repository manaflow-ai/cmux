/// What a page tells the view it shows in (host mode, where cmux's ``ChromiumHostPageView`` is that
/// view): the pane keeps it for the browser and applies it while the browser's tab is the one shown
/// (`CEFPaneHost.pageViewChanged(_:browser:)`), as Chrome's browser process sends the same to the
/// app shim's `RenderWidgetHostNSView`.
nonisolated enum CEFPageViewEvent: Equatable, Sendable {
    /// The page's cursor changed (CURSOR; host mode turns it on).
    case cursor(CEFPageCursor)
    /// The renderer's answer to a drag over the page (DRAG_OPERATION, task 050): the
    /// `cef_drag_operations_mask_t` it takes, 0 none.
    case dragOperation(Int64)
    /// The page's tooltip changed (TOOLTIP, task 054; host mode turns it on): the text, "" for none.
    case tooltip(String)
}
