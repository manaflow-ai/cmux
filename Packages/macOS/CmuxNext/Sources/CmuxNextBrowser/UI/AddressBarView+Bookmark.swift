public import AppKit

// The bookmark star (plans/cmux-next/bookmarks.md section 3): shown at the
// trailing end of the omnibar while the page can be bookmarked and the user
// is not typing in the field (it hides while you type, as in Chrome).
extension AddressBarView {
    /// Sets the star for the page on screen. The host recomputes it when the
    /// URL or the bookmarks change.
    public func setBookmarkStar(_ state: BookmarkStarState) {
        // A hidden star is not made (`OmnibarTrailingBadges`).
        guard state != .hidden || badges.starIfMade != nil else { return }
        starButton.state = state
        updateStarVisibility()
    }

    public var bookmarkStarState: BookmarkStarState { badges.starIfMade?.state ?? .hidden }

    /// The star was pressed; the argument is the anchor for the edit bubble.
    public var onBookmarkStar: ((NSView) -> Void)? {
        get { badges.onStar }
        set { badges.onStar = newValue }
    }

    /// The star view, to anchor the edit bubble from a keyboard or palette
    /// command (nil while hidden).
    public var bookmarkStarAnchor: NSView? { badges.starIfMade.flatMap { $0.isHidden ? nil : $0 } }

    /// The star hides while the user types, not on focus (Chromium
    /// `LocationBarView::IsEditingOrEmpty`): a focusing click keeps the
    /// field's width, so the press relays nothing and the caret lands where
    /// the pointer is.
    func updateStarVisibility() {
        guard let starButton = badges.starIfMade else { return }
        let hidden = starButton.state == .hidden || state.phase == .editing
        guard starButton.isHidden != hidden else { return }
        starButton.isHidden = hidden
        updateBadgeSpace()
    }
}
