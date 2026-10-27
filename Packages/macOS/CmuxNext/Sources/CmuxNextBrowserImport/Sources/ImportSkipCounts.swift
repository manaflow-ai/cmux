/// Entries of a source's bookmarks, history or open tabs that a reader left out, by reason, so a
/// damaged profile reports what it lost (cookies and passwords count theirs in ``CookieReadResult``
/// and ``LoginSkipCounts``). Entries that are by design not data (Firefox tag assignments, hidden
/// Chromium pages, Safari's History proxy, rows past the history limit) are not counted.
public struct ImportSkipCounts: Sendable, Codable, Equatable {
    /// No address, or one that is not a web page or a file (``ImportableURL``): `chrome://`, `about:`.
    public var notImportable = 0
    /// A visit time that is missing or outside years 1-9999 (``BrowserTime``).
    public var badTime = 0
    /// A folder the file names again, inside itself or from a second parent: it is read once.
    public var repeatedFolder = 0
    /// A folder deeper than ``maximumDepth``.
    public var tooDeep = 0
    /// Entries past a reader's cap on how many it reads (a folder not opened counts once).
    public var overLimit = 0
    /// An entry the reader does not read: an unknown kind, a dangling id, a tab with no page.
    public var unsupported = 0

    /// Folders deeper than this are not opened.
    public static let maximumDepth = 64

    public init() {}

    public var total: Int { notImportable + badTime + repeatedFolder + tooDeep + overLimit + unsupported }

    public static func + (lhs: ImportSkipCounts, rhs: ImportSkipCounts) -> ImportSkipCounts {
        var sum = lhs
        sum.notImportable += rhs.notImportable
        sum.badTime += rhs.badTime
        sum.repeatedFolder += rhs.repeatedFolder
        sum.tooDeep += rhs.tooDeep
        sum.overLimit += rhs.overLimit
        sum.unsupported += rhs.unsupported
        return sum
    }
}

/// What a reader got from one file: the entries, and the ones it left out by reason.
public struct ImportRead<Item: Sendable>: Sendable {
    public var items: [Item]
    public var skipped: ImportSkipCounts

    public init(items: [Item] = [], skipped: ImportSkipCounts = ImportSkipCounts()) {
        self.items = items
        self.skipped = skipped
    }
}
