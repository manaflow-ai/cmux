import CoreGraphics

extension CEFSidePanelState {
    /// The web contents' part of a page window that covers `page` (a
    /// non-flipped view): Chromium draws an open side panel inside the page
    /// window, as a full-height column under its header, on the side the
    /// header is on. The contents keep the rest.
    func contentsFrame(inPage page: CGRect) -> CGRect {
        // The header spans the panel's width; its x is from the page's left edge.
        let panelMinX = page.minX + header.minX, panelMaxX = page.minX + header.maxX
        if header.midX >= page.width / 2 {
            return CGRect(x: page.minX, y: page.minY, width: max(0, panelMinX - page.minX), height: page.height)
        }
        return CGRect(x: panelMaxX, y: page.minY, width: max(0, page.maxX - panelMaxX), height: page.height)
    }
}
