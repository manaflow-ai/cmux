public import Foundation

/// The staged update's top changes for the "Update ready" popover and card
/// (cx-ncc.45.5, Lawrence 2026-10-11: "hint at the new stuff, not just link
/// to release notes"). Data only: the whats-new-design lane draws it in React
/// from this value's JSON. Contract: plans in .cmux-scratch/hq-ff/updates/
/// highlights-contract.md (fields, fallback order).
///
/// Built from what is already on disk once the update is staged (the signed
/// release notes fetched and verified at staging, else the appcast item), so
/// it needs no network and no restart.
nonisolated public struct UpdateHighlights: Codable, Equatable, Sendable {
    /// Which data filled ``items`` (the first one with at least one item).
    public enum Source: String, Codable, Sendable {
        case whatsNew, highlights, summary, appcast, none
    }

    public enum Category: String, Codable, Sendable {
        case new, improved, fixed, security
    }

    public struct Item: Codable, Equatable, Sendable {
        public var id: String
        /// Short title, already localized.
        public var title: String
        /// One line, already localized; nil when the source has none.
        public var summary: String?
        public var category: Category
        /// An SF Symbol the source names; never required.
        public var symbol: String?

        public init(id: String, title: String, summary: String?, category: Category, symbol: String? = nil) {
            self.id = id
            self.title = title
            self.summary = summary
            self.category = category
            self.symbol = symbol
        }
    }

    /// The span "See all changes" opens.
    public struct Changelog: Codable, Equatable, Sendable {
        public var from: String
        public var to: String
    }

    /// Shown at most.
    public static let shownItems = 3

    public var version: String
    public var build: String
    public var fromVersion: String
    public var fromBuild: String
    /// Build date, "YYYY-MM-DD".
    public var date: String?
    /// When the build was made, an ISO 8601 instant: the notes' `builtAt`, else the appcast item's
    /// date when it has a time of day (Leo 2026-10-26: "it just says updated to nightly, but that
    /// doesn't mean anything"). The card shows it in the person's time zone. Nil when only the day is known.
    public var builtAt: String?
    /// The commit the build was cut from (the notes' `head`); the card names the build by it.
    public var head: String?
    /// Builds taken off the feed (its `pulled.json`): the card does not count them as newer.
    public var pulled: [String]?
    public var source: Source
    /// The language the strings resolved to (Apple code).
    public var language: String
    public var items: [Item]
    /// Changes not in ``items``.
    public var moreCount: Int
    /// Every change after ``items``, in display order: the update-ready popover scrolls to the
    /// whole list (2026-10-20). Nil in a record saved before this field existed.
    public var rest: [Item]?
    public var changelog: Changelog

    /// Picks the first source with at least one item: the notes' What's New
    /// document, their highlights, their summary, then the appcast lines.
    /// `languages` is the person's preference order.
    public init(version: String, build: String, fromVersion: String, fromBuild: String, notes: ReleaseNotes?,
                appcast: UpdateChangelog?, languages: [String] = Locale.preferredLanguages) {
        self.version = version
        self.build = build
        self.fromVersion = fromVersion
        self.fromBuild = fromBuild
        date = notes?.date ?? appcast?.date.map { Self.day($0) }
        builtAt = notes?.builtAt ?? appcast?.date.flatMap(Self.instant)
        head = notes?.head
        changelog = Changelog(from: fromVersion, to: version)
        let (source, language, all) = Self.pick(notes: notes, appcast: appcast, languages: languages)
        self.source = source
        self.language = language
        items = Array(all.prefix(Self.shownItems))
        moreCount = max(0, all.count - Self.shownItems)
        rest = Array(all.dropFirst(Self.shownItems))
    }

    static func pick(notes: ReleaseNotes?, appcast: UpdateChangelog?, languages: [String]) -> (Source, String, [Item]) {
        if let document = notes?.whatsNew, !document.entries.isEmpty {
            let order: [WhatsNewDocument.Category] = [.new, .improved, .fixed, .security]
            let entries = document.entries.sorted { (order.firstIndex(of: $0.category) ?? 9) < (order.firstIndex(of: $1.category) ?? 9) }
            let items = entries.map { entry in
                Item(id: entry.id, title: entry.title.resolved(for: languages),
                     summary: Self.oneLine(entry.summary.resolved(for: languages)), category: Category(entry.category))
            }
            return (.whatsNew, Self.language(of: document.entries.first?.title, for: languages), items)
        }
        if let highlights = notes?.highlights, !highlights.isEmpty {
            return (.highlights, "en", highlights.map { Item(id: $0.id, title: $0.title, summary: Self.oneLine($0.body), category: .new) })
        }
        if let summary = notes?.summary, !summary.isEmpty {
            let items = summary.enumerated().map { index, line in
                Item(id: "summary-\(index)", title: line.title, summary: nil, category: Category(group: line.group))
            }
            return (.summary, "en", items)
        }
        if let lines = appcast?.lines, !lines.isEmpty {
            let items = lines.enumerated().map { index, line -> Item in
                let (category, title) = Self.categorized(line)
                return Item(id: "appcast-\(index)", title: title, summary: nil, category: category)
            }
            return (.appcast, "en", items)
        }
        return (.none, "en", [])
    }

    /// "New: X" / "Fixed: X" / "Changed: X" as written in the appcast.
    static func categorized(_ line: String) -> (Category, String) {
        for (prefix, category) in [("New:", Category.new), ("Fixed:", .fixed), ("Changed:", .improved), ("Improved:", .improved)]
            where line.hasPrefix(prefix) {
            return (category, line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces))
        }
        return (.improved, line)
    }

    /// The first line, trimmed; nil when empty.
    static func oneLine(_ text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return line.isEmpty ? nil : line
    }

    /// The first of `languages` the text carries, else English.
    static func language(of text: WhatsNewText?, for languages: [String]) -> String {
        guard let text else { return "en" }
        for language in languages {
            for candidate in WhatsNewText.candidates(language) where !(text.values[candidate] ?? "").isEmpty {
                return candidate
            }
        }
        return "en"
    }

    /// "2026-10-26T19:38:52Z"; nil for midnight UTC, which is a day the notes gave
    /// (``UpdateChangelog/init(notes:version:)``), not a time. A saved record does not say which
    /// it was, and a day shown as a time would read as the evening before west of UTC; an
    /// appcast time of exactly 00:00:00 only falls back to its day.
    static func instant(_ date: Date) -> String? {
        let formatter = ISO8601DateFormatter()
        let text = formatter.string(from: date)
        return text.hasSuffix("T00:00:00Z") ? nil : text
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

nonisolated extension UpdateHighlights.Category {
    init(_ category: WhatsNewDocument.Category) {
        switch category {
        case .new: self = .new
        case .improved: self = .improved
        case .fixed: self = .fixed
        case .security: self = .security
        }
    }

    /// A release-notes summary group (`new`, `fixed`, `changed`).
    init(group: String) {
        switch group {
        case "new": self = .new
        case "fixed": self = .fixed
        default: self = .improved
        }
    }
}
