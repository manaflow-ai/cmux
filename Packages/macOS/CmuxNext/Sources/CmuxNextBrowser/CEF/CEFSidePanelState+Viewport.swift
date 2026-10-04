import CoreGraphics

extension CEFSidePanelState {
    /// The web contents' part of a page window that covers `page` (a
    /// non-flipped view): Chromium draws an open side panel inside the page
    /// window, as a full-height column under its header, on the side the
    /// header is on. The contents keep the rest.
    func contentsFrame(inPage page: CGRect) -> CGRect {
        page // red
    }
}
