public import Foundation

/// One entry of a tab's back/forward list.
public nonisolated struct BrowserNavigationEntry: Hashable, Sendable {
    public var url: URL?
    public var title: String?

    public init(url: URL?, title: String?) {
        self.url = url
        self.title = title
    }
}

/// A tab's back/forward list, oldest first, with the current entry.
public nonisolated struct BrowserNavigationList: Hashable, Sendable {
    public var entries: [BrowserNavigationEntry]
    public var current: Int

    public init(entries: [BrowserNavigationEntry], current: Int) {
        self.entries = entries
        self.current = current
    }

    /// Entries Back reaches, nearest first, with their offsets (-1, -2, ...).
    public var back: [(offset: Int, entry: BrowserNavigationEntry)] {
        guard entries.indices.contains(current) else { return [] }
        return (0..<current).reversed().map { (offset: $0 - current, entry: entries[$0]) }
    }

    /// Entries Forward reaches, nearest first, with their offsets (1, 2, ...).
    public var forward: [(offset: Int, entry: BrowserNavigationEntry)] {
        guard entries.indices.contains(current) else { return [] }
        return ((current + 1)..<entries.count).map { (offset: $0 - current, entry: entries[$0]) }
    }
}

/// A tab that can list its back/forward entries and jump to one in a
/// single navigation (the long-press / right-click Back and Forward
/// menus, plans/cmux-next/history.md 4.1). WebKit always; Chromium from
/// fork API 14.
public protocol BrowserBackForwardListing: AnyObject {
    func navigationList() -> BrowserNavigationList?
    /// Goes `offset` entries from the current one (negative: back).
    @discardableResult
    func goToEntry(offset: Int) -> Bool
}
