import CmuxNextActions
import CmuxNextBookmarks
import CmuxNextBrowser
import Foundation

/// Turns an invocation into a browser profile, a bookmark and a folder:
/// `--target bookmark:<id>` (a right-click on the bar), else the `bookmark`
/// argument as an id, an exact URL, or text matched like the omnibar does.
@MainActor
struct BookmarkResolver {
    let services: AppServices

    /// The focused browser tab's key (or the targeted tab's).
    func browserTabKey(_ invocation: ActionInvocation) -> String? {
        if let target = invocation.target, target.kind == .tab { return target.id }
        guard let tab = services.windows.active?.focusedPane?.selectedTab, tab.kind == .browser else { return nil }
        return tab.id
    }

    /// `profile` argument, else the focused browser tab's profile, else `default`.
    func profile(_ invocation: ActionInvocation) -> String {
        if let explicit = invocation["profile"]?.targetValue?.id ?? invocation["profile"]?.stringValue { return explicit }
        if let target = invocation.target, target.kind == .bookmark,
           let owner = services.bookmarks.trees.first(where: { $0.value.node(target.id) != nil })?.key {
            return owner
        }
        if let key = browserTabKey(invocation) { return services.bookmarks.profile(ofTab: key) }
        return BrowserProfileRecord.defaultID
    }

    func node(_ invocation: ActionInvocation, profile: String) throws -> BookmarkNode {
        let tree = services.bookmarks.tree(profile)
        if let target = invocation.target, target.kind == .bookmark {
            guard let node = tree.node(target.id) else { throw ActionFailure(message: BookmarkAppStrings.notFound) }
            return node
        }
        guard let text = invocation["bookmark"]?.stringValue?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            // No name: the focused page's bookmark.
            if let key = browserTabKey(invocation), let url = services.cache.existingBrowser(key)?.tab.state.url,
               let node = tree.bookmarks(for: url).first { return node }
            throw ActionFailure(message: BookmarkAppStrings.needsBookmark)
        }
        if let node = tree.node(text) { return node }
        if let url = URL(string: text), url.scheme != nil, let node = tree.bookmarks(for: url).first { return node }
        if let match = BookmarkRanker.matches(in: tree.bookmarks, for: text, now: Date(), limit: 1).first { return match.node }
        if let folder = BookmarkSearch.results(tree, text: text).first { return folder }
        throw ActionFailure(message: BookmarkAppStrings.notFound)
    }

    /// The `folder` argument: `bar`, `other`, a folder id, or a folder title
    /// (first match in tree order); absent means the default folder.
    func folder(_ invocation: ActionInvocation, profile: String) throws -> String {
        let tree = services.bookmarks.tree(profile)
        guard let text = invocation["folder"]?.stringValue?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            return services.bookmarks.defaultFolder(profile: profile)
        }
        if tree.isContainer(text) { return text }
        let folded = text.lowercased()
        if folded == BookmarkStrings.barTitle.lowercased() { return BookmarkRoot.bar.rawValue }
        if folded == BookmarkStrings.otherBookmarks.lowercased() { return BookmarkRoot.other.rawValue }
        if let folder = tree.ordered.first(where: { $0.isFolder && $0.title.lowercased() == folded }) { return folder.id }
        throw ActionFailure(message: BookmarkAppStrings.notFolder)
    }
}
