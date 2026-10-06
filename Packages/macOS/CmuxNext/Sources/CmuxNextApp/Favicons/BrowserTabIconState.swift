import CmuxNextIcons
import CmuxNextTabs

/// What a browser tab shows where its icon goes (Chromium's `TabIcon`
/// rule): the throbber while the page loads, else the page's favicon, else
/// the browser icon (no favicon yet, none, or its fetch failed). Pure.
enum BrowserTabIconState: Equatable {
    case throbber
    case favicon(TabImage)
    case globe

    /// `isLoading` is the live page's load state; a hibernated tab has no
    /// live page, so it shows its favicon and never the throbber.
    static func resolve(isLoading: Bool, isDormant: Bool, favicon: TabImage?) -> BrowserTabIconState {
        if isLoading, !isDormant { return .throbber }
        return favicon.map(BrowserTabIconState.favicon) ?? .globe
    }

    /// Applies this state to a strip item (the throbber is the strip's busy
    /// spinner in place of the icon; the browser icon is the item's default).
    func apply(to item: inout TabItem) {
        switch self {
        case .throbber: item.isBusy = true
        case .favicon(let image): item.icon = .image(image)
        case .globe: item.icon = .icon(.browser)
        }
    }
}
