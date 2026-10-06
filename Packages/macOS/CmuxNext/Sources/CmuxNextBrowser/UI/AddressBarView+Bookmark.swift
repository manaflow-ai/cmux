public import AppKit

// The bookmark star (plans/cmux-next/bookmarks.md section 3): shown at the
// trailing end of the omnibar while the page can be bookmarked and the field
// is not being edited (it hides while you type).
extension AddressBarView {
    /// Sets the star for the page on screen. The host recomputes it when the
    /// URL or the bookmarks change.
    public func setBookmarkStar(_ state: BookmarkStarState) {
        starButton.state = state
        updateStarVisibility()
    }

    public var bookmarkStarState: BookmarkStarState { starButton.state }

    /// The star was pressed; the argument is the anchor for the edit bubble.
    public var onBookmarkStar: ((NSView) -> Void)? {
        get { starButton.onPress }
        set { starButton.onPress = newValue }
    }

    /// The star view, to anchor the edit bubble from a keyboard or palette
    /// command (nil while hidden).
    public var bookmarkStarAnchor: NSView? { starButton.isHidden ? nil : starButton }

    func updateStarVisibility() {
        let hidden = starButton.state == .hidden || state.hasFocus
        guard starButton.isHidden != hidden else { return }
        starButton.isHidden = hidden
        updateBadgeSpace()
    }
}
