/// `browser.showBookmarksBar` in cmux.json: the bookmarks bar under every
/// browser toolbar (plans/cmux-next/bookmarks.md). Off by default, as in Chrome.
public nonisolated enum BookmarksBarSetting {
    public static let configPath = ["browser", "showBookmarksBar"]
}
