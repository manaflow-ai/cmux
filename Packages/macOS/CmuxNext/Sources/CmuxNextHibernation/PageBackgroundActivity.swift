package import Foundation

/// Which hidden pages changed their title or icon while hidden: the fact of
/// ``DiscardRule/backgroundActivity``. Pure: its owner reports each page's look when it hides and
/// after each change, and forgets the page when it shows.
///
/// Chrome's `PageLiveStateDecorator::Data::UpdatedTitleOrFaviconInBackground`
/// (components/performance_manager/public/decorators/page_live_state_decorator.h): set by a title or
/// favicon update of a page that is not visible, cleared when it becomes visible. As in
/// `PerformanceManagerTabHelper::TitleWasSet` and `DidUpdateFaviconURL`
/// (components/performance_manager/performance_manager_tab_helper.cc), the first title and the
/// first icon of each document do not count: a page that loads hidden is not active. A document
/// starts at each commit, a reload of the same address too, and never at a same-document
/// navigation (pushState, a fragment), as Chrome resets those flags in `PrimaryPageChanged`.
///
/// ```swift
/// var activity = PageBackgroundActivity()
/// activity.hide("tab", look: .init(document: 1, title: "Inbox", icon: icon))
/// activity.note("tab", look: .init(document: 1, title: "Inbox (1)", icon: icon)) // true
/// activity.contains("tab")                                                      // true
/// ```
package nonisolated struct PageBackgroundActivity: Sendable {
    /// What a page shows in its tab: the facts whose change is background activity.
    package nonisolated struct Look: Hashable, Sendable {
        /// The committed document (`BrowserTabState.documentGeneration`); a new one starts over
        /// (its first title and icon do not count). An address change alone keeps it.
        package var document: UInt64
        package var title: String?
        package var icon: URL?

        package init(document: UInt64 = 0, title: String? = nil, icon: URL? = nil) {
            self.document = document
            self.title = title
            self.icon = icon
        }
    }

    private nonisolated struct Seen: Sendable {
        var look: Look
        /// The document had a title (an icon) already: the next one is activity.
        var titleSet: Bool
        var iconSet: Bool

        /// What a page shows as it hides, or as a new document after `previous`: a title or an
        /// icon still equal to the previous document's is that document's, not this one's first.
        init(_ look: Look, after previous: Look? = nil) {
            self.look = look
            titleSet = look.title != nil && look.title != previous?.title
            iconSet = look.icon != nil && look.icon != previous?.icon
        }
    }

    private var seen: [String: Seen] = [:]
    /// The hidden pages that changed their title or icon since they hid.
    package private(set) var active: Set<String> = []

    package init() {}

    /// Page `key` hid showing `look`: its changes from now on count, an earlier hidden period's do not.
    ///
    /// - Parameters:
    ///   - key: The page.
    ///   - look: What it shows as it hides.
    package mutating func hide(_ key: String, look: Look) {
        seen[key] = Seen(look)
        active.remove(key)
    }

    /// Page `key` shows `look` now; a page that is not hidden (no ``hide(_:look:)``) is ignored.
    ///
    /// - Parameters:
    ///   - key: The page.
    ///   - look: What it shows now.
    ///   - counts: False while an agent drives the page: its change becomes what the page shows,
    ///     and only a later change of the page's own can make it active.
    /// - Returns: True when this change made the page active.
    @discardableResult
    package mutating func note(_ key: String, look: Look, counts: Bool = true) -> Bool {
        guard var page = seen[key] else { return false }
        defer { seen[key] = page }
        guard look.document == page.look.document else {
            page = Seen(look, after: page.look)
            return false
        }
        var changed = false
        if let title = look.title, title != page.look.title {
            changed = changed || page.titleSet
            page.titleSet = true
        }
        if let icon = look.icon, icon != page.look.icon {
            changed = changed || page.iconSet
            page.iconSet = true
        }
        page.look = look
        guard changed, counts else { return false }
        return active.insert(key).inserted
    }

    /// Whether hidden page `key` changed its title or icon since it hid.
    package func contains(_ key: String) -> Bool {
        active.contains(key)
    }

    /// Page `key` showed, was discarded or closed: its fact and its watch end.
    package mutating func forget(_ key: String) {
        seen[key] = nil
        active.remove(key)
    }
}
