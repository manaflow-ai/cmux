public import Foundation

/// One back/forward entry saved before a relaunch: the page, its title, and
/// how far down it was scrolled.
public nonisolated struct BrowserSavedEntry: Hashable, Sendable {
    public var url: URL
    public var title: String?
    public var scrollY: Double?

    public init(url: URL, title: String? = nil, scrollY: Double? = nil) {
        self.url = url
        self.title = title
        self.scrollY = scrollY
    }

    var navigationEntry: BrowserNavigationEntry { BrowserNavigationEntry(url: url, title: title) }
}

/// Back/forward entries saved before a relaunch that the engine no longer
/// has (plans/cmux-next/browser.md, "Session history across relaunch").
/// The page shows one saved entry; `back` and `forward` hold the others.
/// Chromium cannot take entries back, so moving into them replaces the
/// engine's first entry with the saved one; the first new navigation of
/// the user's drops `forward`, as a browser does. `forward` is non-empty
/// only while the engine is on its first entry.
public nonisolated struct BrowserRestoredHistory: Hashable, Sendable {
    /// Oldest first.
    public private(set) var back: [BrowserSavedEntry]
    /// Nearest first.
    public private(set) var forward: [BrowserSavedEntry]

    /// The entries around `entries[current]`, the one the page shows; nil
    /// when there is no other entry.
    public init?(entries: [BrowserSavedEntry], current: Int) {
        guard entries.indices.contains(current), entries.count > 1 else { return nil }
        back = Array(entries[..<current])
        forward = Array(entries[(current + 1)...])
    }

    private init() {
        back = []
        forward = []
    }

    /// No saved entries: the engine's own list is the whole history.
    public static let empty = BrowserRestoredHistory()

    public var isEmpty: Bool { back.isEmpty && forward.isEmpty }

    /// Goes `steps` saved entries back from `shown` and returns the entry to
    /// show; `shown` and the entries passed over move to `forward`.
    public mutating func goBack(_ steps: Int = 1, from shown: BrowserSavedEntry) -> BrowserSavedEntry? {
        guard steps > 0, steps <= back.count else { return nil }
        let start = back.count - steps
        let target = back[start]
        forward.insert(contentsOf: back[(start + 1)...] + [shown], at: 0)
        back.removeLast(steps)
        return target
    }

    /// Goes `steps` saved entries forward from `shown` and returns the entry
    /// to show; `shown` and the entries passed over move to `back`.
    public mutating func goForward(_ steps: Int = 1, from shown: BrowserSavedEntry) -> BrowserSavedEntry? {
        guard steps > 0, steps <= forward.count else { return nil }
        let target = forward[steps - 1]
        back.append(shown)
        back.append(contentsOf: forward[..<(steps - 1)])
        forward.removeFirst(steps)
        return target
    }

    /// A new navigation of the user's: the saved forward entries are gone.
    public mutating func dropForward() {
        forward.removeAll()
    }

    /// The saved entries, with their scroll positions, around the engine's
    /// own list (`native`, else just the shown page), for saving.
    public func session(around native: BrowserNavigationList?, shown: BrowserNavigationEntry) -> BrowserSavedSession {
        let own = native ?? BrowserNavigationList(entries: [shown], current: 0)
        // An entry without a URL (nothing committed) cannot be saved.
        let saved = own.entries.map { entry in entry.url.map { BrowserSavedEntry(url: $0, title: entry.title) } }
        var arranged: [BrowserSavedEntry?] = back.map(Optional.some)
        arranged += saved.prefix(1)
        arranged += forward.map(Optional.some)
        arranged += saved.dropFirst()
        let entries = arranged.compactMap(\.self)
        let before = arranged.prefix(position(of: own)).filter { $0 != nil }.count
        return BrowserSavedSession(entries: entries, current: min(before, max(entries.count - 1, 0)))
    }

    /// The saved entries around the engine's own list (`native`, else just
    /// the shown page), for the Back and Forward menus. `back` comes before
    /// the engine's first entry and `forward` right after it: a step back
    /// into the saved entries replaces the engine's first entry, so the
    /// entries passed over sit between it and the engine's next one.
    public func merged(with native: BrowserNavigationList?, shown: BrowserNavigationEntry) -> BrowserNavigationList {
        let own = native ?? BrowserNavigationList(entries: [shown], current: 0)
        var entries = back.map(\.navigationEntry)
        entries += own.entries.prefix(1)
        entries += forward.map(\.navigationEntry)
        entries += own.entries.dropFirst()
        return BrowserNavigationList(entries: entries, current: position(of: own))
    }

    /// Where the engine's current entry sits in `merged`.
    public func position(of own: BrowserNavigationList) -> Int {
        back.count + (own.current == 0 ? 0 : forward.count + own.current)
    }
}
