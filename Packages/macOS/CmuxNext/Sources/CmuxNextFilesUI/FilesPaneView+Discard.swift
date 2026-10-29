public import AppKit

/// What the host needs to discard a hidden Files pane and show it again (`memoryDiscardInternalPages`):
/// whether a window the pane opened still shows, and the shown layout's scroll.
extension FilesPaneView {
    /// A Get Info panel this pane opened still shows; ``stop()`` would close it.
    public var showsInfoPanels: Bool { !infoWindows.isEmpty }

    /// Where the list or icon layout is scrolled; nil for the column layout, which shows its selection.
    public var contentScroll: CGPoint? {
        (currentContent?.view as? NSScrollView)?.documentVisibleRect.origin
    }

    /// Scrolls the list or icon layout to `point`.
    public func scrollContent(to point: CGPoint) {
        guard let scroll = currentContent?.view as? NSScrollView else { return }
        scroll.contentView.scroll(to: point)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
