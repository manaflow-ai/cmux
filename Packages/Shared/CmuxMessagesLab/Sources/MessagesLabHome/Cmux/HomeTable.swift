import CoreGraphics
import Foundation

/// cmux: a Markdown pipe table in a Home reply (Leo 2026-10-20: a three-column table squeezed into a
/// bubble wrapped every cell into a tall column of words). Home draws it as a card of its own at the
/// chat's full width with real column widths (``HomeTableRowProvider``), or, when it is an
/// assignment list (who does what, with an owner column of subagent ids), as the Chief's plan card
/// (``HomePlanCard``). Values only; ``HomeTableSplitter`` finds them in a reply's text.
struct HomeTable: Codable, Hashable, Sendable {
    enum Alignment: String, Codable, Hashable, Sendable { case leading, center, trailing }

    /// The header cells, Markdown as written.
    var header: [String]
    var alignments: [Alignment]
    /// Body rows, each padded or cut to the header's column count.
    var rows: [[String]]

    var columns: Int { header.count }
}

/// A reply's text cut at its pipe tables: the text between them as written, each table parsed with
/// the exact Markdown it came from (a table Home refuses joins the text again).
struct HomeTableSplitter {
    enum Segment: Equatable {
        case text(String)
        case table(HomeTable, raw: String)
    }

    /// Tables larger than this stay text (a pasted CSV is not a card).
    static let maxRows = 200
    static let maxColumns = 12

    func segments(in text: String) -> [Segment] {
        guard text.contains("|") else { return [.text(text)] }
        let lines = text.components(separatedBy: "\n")
        var out: [Segment] = []
        var pending: [String] = []
        var fence: String?
        var i = 0
        func flush() {
            guard !pending.isEmpty else { return }
            out.append(.text(pending.joined(separator: "\n")))
            pending = []
        }
        while let line = lines[checked: i] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Fenced code stays as written: a table inside a fence is code.
            if let open = fence {
                pending.append(line)
                if trimmed.hasPrefix(open) { fence = nil }
                i += 1
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
                pending.append(line)
                i += 1
                continue
            }
            if let next = lines[checked: i + 1], let header = Self.cells(line), header.count >= 2,
               let alignments = Self.delimiter(next, columns: header.count) {
                var rows: [[String]] = []
                var j = i + 2
                while let row = lines[checked: j], !row.trimmingCharacters(in: .whitespaces).isEmpty, let cells = Self.cells(row) {
                    rows.append(Self.fit(cells, header.count))
                    j += 1
                }
                if !rows.isEmpty, rows.count <= Self.maxRows, header.count <= Self.maxColumns {
                    flush()
                    let raw = lines.dropFirst(i).prefix(j - i).joined(separator: "\n")
                    out.append(.table(HomeTable(header: header, alignments: alignments, rows: rows), raw: raw))
                    i = j
                    continue
                }
            }
            pending.append(line)
            i += 1
        }
        flush()
        return out
    }

    /// A row's cells: the line must hold a pipe outside code spans and escapes; the outer pipes are
    /// optional. nil for a line that is not a table row.
    static func cells(_ line: String) -> [String]? {
        var s = line.trimmingCharacters(in: .whitespaces)
        guard s.contains("|") else { return nil }
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|"), !s.hasSuffix("\\|") { s.removeLast() }
        var cells: [String] = []
        var cell = ""
        var code = false
        var escaped = false
        for ch in s {
            if escaped {
                cell.append(ch == "|" ? "|" : "\\\(ch)")
                escaped = false
                continue
            }
            switch ch {
            case "\\": escaped = true
            case "`": code.toggle(); cell.append(ch)
            case "|" where !code:
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            default: cell.append(ch)
            }
        }
        if escaped { cell.append("\\") }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells.count >= 2 ? cells : nil
    }

    /// The delimiter row (`|---|:---:|--:|`) for `columns` columns: each column's alignment.
    static func delimiter(_ line: String, columns: Int) -> [HomeTable.Alignment]? {
        guard let cells = cells(line), cells.count == columns else { return nil }
        var out: [HomeTable.Alignment] = []
        for cell in cells {
            let left = cell.hasPrefix(":"), right = cell.hasSuffix(":")
            let dashes = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            out.append(left && right ? .center : right ? .trailing : .leading)
        }
        return out
    }

    static func fit(_ cells: [String], _ count: Int) -> [String] {
        cells.count >= count ? Array(cells.prefix(count)) : cells + Array(repeating: "", count: count - cells.count)
    }
}

/// A table cell's Markdown as the card shows it: the text without emphasis and code marks, its
/// links' titles in place, and the links it carries.
struct HomeTableCell: Hashable, Sendable {
    var text: String
    /// Ranges (in `text`, UTF-16) that were `**bold**`.
    var bold: [NSRange]
    var links: [URL]

    init(markdown: String) {
        var text = ""
        var bold: [NSRange] = []
        var links: [URL] = []
        var boldStart: Int?
        let chars = Array(markdown)
        var i = 0
        func length() -> Int { (text as NSString).length }
        while let ch = chars[checked: i] {
            if ch == "*" || ch == "_", chars[checked: i + 1] == ch {
                if let start = boldStart {
                    bold.append(NSRange(location: start, length: length() - start))
                    boldStart = nil
                } else {
                    boldStart = length()
                }
                i += 2
                continue
            }
            if ch == "`" {
                i += 1
                continue
            }
            // [title](url)
            if ch == "[", let close = chars.dropFirst(i + 1).firstIndex(of: "]"), chars[checked: close + 1] == "(",
               let end = chars.dropFirst(close + 2).firstIndex(of: ")") {
                let title = String(chars.dropFirst(i + 1).prefix(close - i - 1))
                let target = String(chars.dropFirst(close + 2).prefix(end - close - 2))
                if let url = URL(string: target), url.scheme != nil {
                    text += title
                    links.append(url)
                    i = end + 1
                    continue
                }
            }
            text.append(ch)
            i += 1
        }
        // A bare link (`https://…`) counts too.
        for word in text.split(whereSeparator: { $0 == " " || $0 == "," || $0 == ";" }) {
            let w = word.trimmingCharacters(in: CharacterSet(charactersIn: "()<>."))
            if w.hasPrefix("https://"), let url = URL(string: w), !links.contains(url) { links.append(url) }
        }
        self.text = text
        self.bold = bold
        self.links = links
    }
}

/// An assignment table as the Chief's plan (Leo 2026-10-20: "design PR / what it builds / who"):
/// one row per step with its owner chip, what it builds, its pull requests and a live state from the
/// ``ChiefPlan`` (else the state the table's own words give).
struct HomePlanCard: Codable, Hashable, Sendable {
    struct Row: Codable, Hashable, Sendable {
        /// The row's first column when it is a short key (`1 + 2`, `PR 3`), else nil.
        var key: String?
        var title: String
        /// The subagent id (`a12`), lowercased; nil for a row without one.
        var owner: String?
        /// The owner cell after its id (`new; workspace "a12 · Nightly train"`).
        var ownerNote: String?
        /// GitHub pull request links in the row, in order, without repeats.
        var pullRequests: [String]
        /// The state the table's own words give (`landed`, `waiting on CI`), when it has a status column.
        var written: ChiefPlanStep.State?
    }

    var rows: [Row]

    /// Header words that name the owner column.
    static let ownerHeaders: Set<String> = ["who", "owner", "owners", "agent", "subagent", "lane", "assignee", "assigned", "assigned to"]
    static let statusHeaders: Set<String> = ["status", "state", "where", "progress"]

    /// The plan card for `table`, or nil when it is not an assignment list: it needs a column whose
    /// header names an owner (Who, Owner, Agent, Lane), and at least half its rows must name a subagent.
    init?(_ table: HomeTable) {
        guard table.columns >= 2 else { return nil }
        let headers = table.header.map { HomeTableCell(markdown: $0).text.lowercased().trimmingCharacters(in: .whitespaces) }
        // Only a header that names an owner: a column of A4 / A1 cells is not a list of subagents.
        guard let ownerColumn = headers.firstIndex(where: { Self.ownerHeaders.contains($0) }) else { return nil }
        let owned = table.rows.filter { Self.ownerID(HomeTableCell(markdown: $0[ownerColumn]).text) != nil }.count
        guard owned * 2 >= table.rows.count, owned > 0 else { return nil }
        let statusColumn = headers.firstIndex { Self.statusHeaders.contains($0) }
        let others = (0..<table.columns).filter { $0 != ownerColumn && $0 != statusColumn }
        // The title is the column with the most words; a short first column before it is the key.
        let words: (Int) -> Int = { c in table.rows.reduce(0) { $0 + HomeTableCell(markdown: $1[c]).text.split(separator: " ").count } }
        guard let titleColumn = others.max(by: { words($0) < words($1) }) else { return nil }
        let keyColumn = others.first { $0 != titleColumn && words($0) <= table.rows.count * 3 }
        rows = table.rows.map { cells in
            let parsed = cells.map(HomeTableCell.init(markdown:))
            let ownerCell = parsed[checked: ownerColumn]?.text ?? ""
            let owner = Self.ownerID(ownerCell)
            let note = owner.flatMap { Self.note(ownerCell, after: $0) }
            var prs: [String] = []
            for cell in parsed {
                for url in cell.links {
                    if let pr = ChiefPlanPullRequest(link: url.absoluteString), !prs.contains(pr.url) { prs.append(pr.url) }
                }
            }
            let key = keyColumn.flatMap { parsed[checked: $0]?.text }.flatMap { $0.isEmpty ? nil : $0 }
            let written = statusColumn.flatMap { parsed[checked: $0] }.flatMap { Self.writtenState($0.text) }
            return Row(key: key, title: parsed[checked: titleColumn]?.text ?? "", owner: owner, ownerNote: note, pullRequests: prs, written: written)
        }
    }

    /// `a12` when `text` starts with a subagent id (`a12`, `**a12**`, `a12, added to …`), lowercased.
    static func ownerID(_ text: String) -> String? {
        let s = text.trimmingCharacters(in: .whitespaces)
        guard let first = s.first, first == "a" || first == "A" else { return nil }
        let digits = s.dropFirst().prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 4 else { return nil }
        let after = s.dropFirst(1 + digits.count).first
        if let after, after.isLetter || after.isNumber { return nil }
        return "a" + digits
    }

    /// The owner cell after its id, without the separator or the parentheses around it:
    /// `a12 (new; workspace …)` is `new; workspace …`; nil when nothing follows.
    static func note(_ cell: String, after owner: String) -> String? {
        let rest = cell.trimmingCharacters(in: .whitespaces).dropFirst(owner.count)
        var note = String(rest).trimmingCharacters(in: CharacterSet(charactersIn: ",;:-–—").union(.whitespaces))
        if note.hasPrefix("("), note.hasSuffix(")") { note = String(note.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces) }
        return note.isEmpty ? nil : note
    }

    /// The state a status cell's words give, or nil.
    static func writtenState(_ text: String) -> ChiefPlanStep.State? {
        let words = Set(text.lowercased().split { !$0.isLetter }.map(String.init))
        let has = { (w: [String]) in !words.isDisjoint(with: w) }
        if has(["landed", "merged", "shipped"]) { return .landed }
        if has(["failed", "failing", "red", "broken"]) { return .ciFailed }
        if has(["ci", "checks"]) { return .waitingOnCI }
        if has(["review", "reviewing", "ready"]) { return .inReview }
        if has(["waiting", "blocked", "needs"]) { return .needsInput }
        if has(["done", "finished", "complete"]) { return .done }
        if has(["working", "running", "building", "started"]) { return .working }
        return nil
    }

    /// Each row's state: the live plan's step for its owner (or one of its pull requests), else what
    /// the table says, else nil (the card then shows no state pill).
    func states(in plan: ChiefPlan) -> [ChiefPlanStep.State?] {
        rows.map { row in
            if let owner = row.owner, let step = plan.step(owner: owner) { return step.state }
            if let step = row.pullRequests.lazy.compactMap({ plan.step(pullRequest: $0) }).first { return step.state }
            return row.written
        }
    }
}

/// Column widths for a table card: each column gets its natural width (its widest cell) when they
/// all fit; otherwise narrow columns keep theirs and the wide ones share the rest in proportion to
/// their natural widths, never under ``minColumn`` (the card then wraps their cells). Pure.
enum HomeTableColumns {
    static let minColumn: CGFloat = 56

    static func widths(natural: [CGFloat], available: CGFloat) -> [CGFloat] {
        guard !natural.isEmpty else { return [] }
        let total = natural.reduce(0, +)
        if total <= available { return natural }
        // A fair share each; columns under it keep their natural width.
        var fixed = Set<Int>()
        var room = available
        while true {
            let open = natural.enumerated().filter { !fixed.contains($0.offset) }
            guard !open.isEmpty else { break }
            let share = room / CGFloat(open.count)
            let small = open.filter { $0.element <= share }
            if small.isEmpty { break }
            for column in small {
                fixed.insert(column.offset)
                room -= column.element
            }
        }
        let openNatural = natural.enumerated().reduce(CGFloat(0)) { fixed.contains($1.offset) ? $0 : $0 + $1.element }
        return natural.enumerated().map { column in
            fixed.contains(column.offset) ? column.element : max(minColumn, (room * column.element / max(1, openNatural)).rounded(.down))
        }
    }
}
