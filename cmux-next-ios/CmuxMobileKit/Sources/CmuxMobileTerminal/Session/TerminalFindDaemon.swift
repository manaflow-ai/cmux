import Foundation

/// Find through the Mac's daemon (`terminal-find`, `cmux-tui/spec/commands.md`): the daemon
/// searches the terminal's whole retained history in Rust and answers newest-first pages of
/// matches. The phone only asks, shows "N of M" and maps each match onto the rows its mirror
/// holds (``TerminalFindRowMap``); a match older than the mirror makes the session load the
/// history around it (``TerminalSession/loadHistory(aroundDaemonRow:rowsFromBottom:)``).
///
/// The toggles of the find bar.
public struct TerminalFindOptions: Equatable, Sendable {
    public var caseSensitive: Bool
    public var wholeWord: Bool
    public var regex: Bool

    public init(caseSensitive: Bool = false, wholeWord: Bool = false, regex: Bool = false) {
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.regex = regex
    }
}

/// One `terminal-find` request: a page of matches ending above `before`.
public struct TerminalFindRequest: Equatable, Sendable {
    public var query: String
    public var options: TerminalFindOptions
    /// The previous page's ``TerminalFindPage/nextBefore`` (nil: the first page, from the bottom).
    public var before: Int?
    /// The previous page's ``TerminalFindPage/epoch``.
    public var epoch: Int?

    public init(query: String, options: TerminalFindOptions, before: Int? = nil, epoch: Int? = nil) {
        self.query = query
        self.options = options
        self.before = before
        self.epoch = epoch
    }

    /// The request's fields, as the daemon takes them (the session adds `surface`).
    public var fields: [String: Any] {
        var fields: [String: Any] = ["query": query]
        if options.caseSensitive { fields["case_sensitive"] = true }
        if options.wholeWord { fields["whole_word"] = true }
        if options.regex { fields["regex"] = true }
        if let before { fields["before"] = before }
        if let epoch { fields["epoch"] = epoch }
        return fields
    }
}

/// A `terminal-find` answer: one page, newest match first.
public struct TerminalFindPage: Equatable, Sendable {
    /// A cell in the daemon's history: the row's marker and its column.
    public struct Point: Equatable, Sendable {
        public var marker: Int
        public var column: Int
    }

    public struct Hit: Equatable, Sendable {
        public var start: Point
        public var end: Point
        /// `bottom - start.marker`: 1 is the bottom row.
        public var rowsFromBottom: Int
        public var snippet: String
    }

    public var hits: [Hit]
    /// Ask for the next (older) page with this `before`; nil once the oldest row was searched.
    public var nextBefore: Int?
    public var complete: Bool
    public var epoch: Int
    /// A resize reflow renumbered the markers: matches already held are stale.
    public var restarted: Bool
    public var bottom: Int
    /// An invalid regex answers ok with no matches and this text.
    public var invalidPattern: String?

    /// The page in a daemon reply line. Throws the daemon's error text; nil when the reply is no page.
    public static func decode(_ reply: Data) throws -> TerminalFindPage {
        guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
            throw TerminalFindError.badReply
        }
        if object["ok"] as? Bool == false { throw TerminalFindError.refused((object["error"] as? String) ?? "refused") }
        if let error = object["error"] as? String { throw TerminalFindError.refused(error) }
        guard let data = object["data"] as? [String: Any], let matches = data["matches"] as? [[String: Any]] else {
            throw TerminalFindError.badReply
        }
        func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
        func point(_ value: Any?) -> Point? {
            guard let value = value as? [String: Any], let marker = int(value["marker"]), let column = int(value["column"]) else { return nil }
            return Point(marker: marker, column: column)
        }
        let hits: [Hit] = matches.compactMap { match in
            guard let start = point(match["start"]), let end = point(match["end"]), let rows = int(match["rows_from_bottom"]) else { return nil }
            return Hit(start: start, end: end, rowsFromBottom: rows, snippet: (match["snippet"] as? String) ?? "")
        }
        return TerminalFindPage(
            hits: hits, nextBefore: int(data["next_before"]), complete: (data["complete"] as? Bool) ?? false,
            epoch: int(data["epoch"]) ?? 0, restarted: (data["restarted"] as? Bool) ?? false,
            bottom: int(data["bottom"]) ?? 0, invalidPattern: data["invalid_pattern"] as? String)
    }
}

public enum TerminalFindError: Error, Equatable, Sendable {
    case badReply
    case refused(String)

    /// The daemon (or the phone's lane) does not know `terminal-find`: search the mirror instead.
    public var isUnsupported: Bool {
        guard case .refused(let reason) = self else { return false }
        let text = reason.lowercased()
        return ["unknown command", "unknown cmd", "not available", "forbidden", "unsupported", "unrecognized"].contains { text.contains($0) }
    }
}

/// What the session knows about the history the mirror holds (`vt-state`'s
/// `history_rows_omitted` and `history_rows_skipped`).
public struct TerminalFindMirror: Equatable, Sendable {
    /// History rows older than the mirror's first row.
    public var omitted: Int
    /// History rows between the window and the screen that the mirror left out.
    public var skipped: Int
    /// Rows of the window far above the screen (nil: the mirror's rows reach the screen).
    public var windowRows: Int?

    public init(omitted: Int, skipped: Int, windowRows: Int?) {
        self.omitted = omitted
        self.skipped = skipped
        self.windowRows = windowRows
    }
}

/// Maps the daemon's rows onto the mirror's. A daemon row is its number from the oldest row
/// the daemon retains; the mirror holds `omitted` rows fewer above it, and (in a window far
/// above the screen) `skipped` rows fewer between its history and its screen.
public struct TerminalFindRowMap: Equatable, Sendable {
    public var mirror: TerminalFindMirror
    /// Rows the mirror holds now (the scrollbar's total).
    public var mirrorRows: Int

    public init(mirror: TerminalFindMirror, mirrorRows: Int) {
        self.mirror = mirror
        self.mirrorRows = mirrorRows
    }

    /// Rows the daemon retains (as the mirror knows them).
    public var daemonRows: Int { mirror.omitted + mirrorRows + mirror.skipped }

    /// The daemon row `rowsFromBottom` rows above its bottom row (1: the bottom row itself).
    public func daemonRow(rowsFromBottom: Int) -> Int { daemonRows - rowsFromBottom }

    /// The mirror's row for `daemonRow`; nil when the mirror does not hold it.
    public func mirrorRow(forDaemonRow daemonRow: Int) -> Int? {
        let historyEnd: Int
        if let windowRows = mirror.windowRows, mirror.skipped > 0 {
            historyEnd = mirror.omitted + windowRows
            if daemonRow >= historyEnd + mirror.skipped {
                let row = daemonRow - mirror.omitted - mirror.skipped
                return row < mirrorRows ? row : nil
            }
        } else {
            historyEnd = mirror.omitted + mirrorRows
        }
        guard daemonRow >= mirror.omitted, daemonRow < historyEnd else { return nil }
        return daemonRow - mirror.omitted
    }
}

extension TerminalFindResults.Match {
    /// The match of a daemon `hit`: its cells on the mirror's rows when the mirror holds them
    /// (the rows between its first and last are covered in full), none when it is older.
    init(hit: TerminalFindPage.Hit, map: TerminalFindRowMap, columns: Int) {
        let first = map.daemonRow(rowsFromBottom: hit.rowsFromBottom)
        let span = max(0, hit.end.marker - hit.start.marker)
        self.init(segments: [], daemon: .init(row: first, span: span, startColumn: hit.start.column, endColumn: hit.end.column))
        place(map: map, columns: columns)
    }

    /// Lays the match on the mirror again (it was replaced, or the match was older than it).
    mutating func place(map: TerminalFindRowMap, columns: Int) {
        guard let daemon else { return }
        var segments: [TerminalLink.Segment] = []
        for offset in 0...daemon.span {
            guard let row = map.mirrorRow(forDaemonRow: daemon.row + offset) else {
                // A match that starts in the mirror and runs out of it is shown as far as it goes.
                if offset == 0 { break } else { continue }
            }
            let start = offset == 0 ? daemon.startColumn : 0
            let end = offset == daemon.span ? daemon.endColumn : max(0, columns - 1)
            segments.append(TerminalLink.Segment(row: row, start: start, end: max(start, end)))
        }
        self.segments = segments
    }
}
