/// Which kind of match the find bar looks for. The daemon's `terminal-find` honors all three.
public struct TerminalFindOptions: Sendable, Equatable {
    /// Match letter case exactly.
    public var caseSensitive = false
    /// Match whole words only.
    public var wholeWord = false
    /// The query is a regular expression.
    public var regex = false

    public init(caseSensitive: Bool = false, wholeWord: Bool = false, regex: Bool = false) {
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.regex = regex
    }
}

/// One hit in a terminal's whole history, as the daemon's `terminal-find` reports it.
public struct TerminalFindMatch: Sendable, Equatable {
    /// Where the match starts: the row's history marker and the cell's column.
    public var startMarker: UInt64
    public var startColumn: Int
    /// The last cell of the match (inclusive).
    public var endMarker: UInt64
    public var endColumn: Int
    /// 1 is the bottom row: the number a mirror with less history maps to its own row.
    public var rowsFromBottom: Int
    /// The matched text.
    public var text: String

    public init(startMarker: UInt64, startColumn: Int, endMarker: UInt64, endColumn: Int, rowsFromBottom: Int, text: String) {
        self.startMarker = startMarker
        self.startColumn = startColumn
        self.endMarker = endMarker
        self.endColumn = endColumn
        self.rowsFromBottom = rowsFromBottom
        self.text = text
    }

    /// Cells from the start through the end, counting a soft-wrapped match's rows `columns` wide.
    public func cellCount(columns: Int) -> Int {
        let rows = Int(truncatingIfNeeded: endMarker &- startMarker)
        return max(1, rows * max(columns, 1) + endColumn - startColumn + 1)
    }
}

/// What a page request asks the daemon.
public struct TerminalFindPageRequest: Sendable, Equatable {
    public var query: String
    public var options: TerminalFindOptions
    /// The previous page's `nextBefore`; nil starts at the newest row.
    public var before: UInt64?
    /// The previous page's `epoch`.
    public var epoch: UInt64?

    public init(query: String, options: TerminalFindOptions, before: UInt64? = nil, epoch: UInt64? = nil) {
        self.query = query
        self.options = options
        self.before = before
        self.epoch = epoch
    }
}

/// One page of matches, newest first.
public struct TerminalFindPage: Sendable, Equatable {
    public var matches: [TerminalFindMatch]
    /// Where the next page starts; nil once the oldest row was searched.
    public var nextBefore: UInt64?
    public var epoch: UInt64
    /// A reflow renumbered the rows: this page starts over at the bottom.
    public var restarted: Bool
    /// The regex did not compile: the reason, with no matches.
    public var invalidPattern: String?
    /// The terminal's columns, which a soft-wrapped match spans.
    public var columns: Int

    public init(matches: [TerminalFindMatch], nextBefore: UInt64?, epoch: UInt64, restarted: Bool = false,
                invalidPattern: String? = nil, columns: Int) {
        self.matches = matches
        self.nextBefore = nextBefore
        self.epoch = epoch
        self.restarted = restarted
        self.invalidPattern = invalidPattern
        self.columns = columns
    }
}

/// The daemon's whole-history search for one terminal. Matching and paging live in Rust
/// (`terminal-find`); this only asks. Throws when the daemon cannot serve it (an older daemon,
/// no connection), which sends the bar back to Ghostty's own screen search.
@MainActor
public protocol TerminalFindHistory: AnyObject {
    func page(_ request: TerminalFindPageRequest) async throws -> TerminalFindPage
}
