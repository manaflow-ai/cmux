import CmuxNextActions
import CmuxNextBookmarks
import CmuxNextBrowser
import Foundation

/// Turns an invocation into a browser profile, a bookmark and a folder: `--target bookmark:<id>`
/// (a right-click on the bar), else the `bookmark` argument as an id, an exact URL, or text
/// matched like the omnibar does. The names resolve on the home daemon's tree
/// (`bookmarks.resolve`, cmux-bookmarks-ops `lookup`): the app holds no copy that could lag it.
@MainActor
struct BookmarkResolver {
    let services: AppServices

    /// The focused browser tab's key (or the targeted tab's).
    func browserTabKey(_ invocation: ActionInvocation) -> String? {
        if let target = invocation.target, target.kind == .tab { return target.id }
        guard let tab = services.windows.active?.focusedPane?.selectedTab, tab.kind == .browser else { return nil }
        return tab.id
    }

    /// `profile` argument, else the profile of the bar whose menu named the bookmark, else the
    /// focused browser tab's profile, else `default`.
    func profile(_ invocation: ActionInvocation) -> String {
        if let explicit = invocation["profile"]?.targetValue?.id ?? invocation["profile"]?.stringValue { return explicit }
        if let target = invocation.target, target.kind == .bookmark, let menu = services.bookmarks.menuTarget, menu.id == target.id {
            return menu.profile
        }
        if let key = browserTabKey(invocation) { return services.bookmarks.profile(ofTab: key) }
        return BrowserProfileRecord.defaultID
    }

    /// What names the bookmark, and whether only an id or a link to the same page may answer it.
    struct Name: Equatable {
        var text: String
        var exact: Bool
    }

    /// What names the bookmark: the target's id, else the `bookmark` argument (matched like the
    /// omnibar does), else the focused page's URL, exactly: a page with no bookmark of its own names
    /// none, never another page's by a text match. Nil when nothing does.
    func name(_ invocation: ActionInvocation) -> Name? {
        if let target = invocation.target, target.kind == .bookmark { return Name(text: target.id, exact: true) }
        if let text = invocation["bookmark"]?.stringValue?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
            return Name(text: text, exact: false)
        }
        guard let key = browserTabKey(invocation), let url = services.cache.existingBrowser(key)?.tab.state.url else { return nil }
        return Name(text: url.absoluteString, exact: true)
    }

    /// The parts an invocation names, resolved in one daemon read: the bookmark when `bookmark`
    /// (folders by title first with `foldersFirst`), the `folder` argument when `folder` (none is
    /// the default folder), the `url` argument when given.
    func resolve(_ invocation: ActionInvocation, profile: String, bookmark: Bool = false, foldersFirst: Bool = false,
                 folder: Bool = false) async throws -> BookmarkRoutedClient.Resolved {
        var name: Name?
        if bookmark {
            guard let named = self.name(invocation) else { throw ActionFailure(message: BookmarkAppStrings.needsBookmark) }
            name = named
        }
        let folderText: String?? = folder ? .some(invocation["folder"]?.stringValue) : nil
        let url = invocation["url"]?.stringValue
        guard services.bookmarks.usesDaemon else {
            throw ActionFailure(message: BookmarkAppStrings.failure(services.bookmarks.unavailable))
        }
        do {
            return try await services.bookmarks.routed.resolve(profile: profile, bookmark: name?.text, exact: name?.exact ?? false,
                                                               foldersFirst: foldersFirst,
                                                               folder: folderText, fallback: services.bookmarks.lastFolder[profile],
                                                               url: url)
        } catch BookmarkError.notFound(_) {
            throw ActionFailure(message: BookmarkAppStrings.notFound)
        } catch BookmarkError.invalidParent(_) {
            throw ActionFailure(message: BookmarkAppStrings.notFolder)
        } catch BookmarkError.invalidURL {
            throw ActionFailure(message: BookmarkAppStrings.invalidURL)
        }
    }

    /// Runs `body` on what the invocation names, as tracked work (the CLI waits for it); a
    /// failure is the action's, shown as a refusal when nobody awaits the run.
    func withResolved(_ invocation: ActionInvocation, bookmark: Bool = false, foldersFirst: Bool = false, folder: Bool = false,
                      _ body: @escaping @MainActor (BookmarkRoutedClient.Resolved, String) async throws -> Void) {
        let profile = profile(invocation)
        services.registry.trackOrRefuse(Task {
            do {
                try await body(try await resolve(invocation, profile: profile, bookmark: bookmark, foldersFirst: foldersFirst,
                                                 folder: folder), profile)
                return nil
            } catch let failure as ActionFailure {
                return ActionWorkFailure(failure.message)
            } catch {
                return ActionWorkFailure(BookmarkAppStrings.failure(error))
            }
        })
    }

    /// ``withResolved(_:bookmark:foldersFirst:folder:_:)`` for the bookmark alone.
    func withNode(_ invocation: ActionInvocation, _ body: @escaping @MainActor (BookmarkNode, String) async throws -> Void) {
        withResolved(invocation, bookmark: true) { resolved, profile in
            guard let node = resolved.bookmark else { throw ActionFailure(message: BookmarkAppStrings.notFound) }
            try await body(node, profile)
        }
    }
}
