public import Foundation

/// The What's New page as data (pure): one section per document, newest
/// first, entries grouped by category in a fixed order. The SwiftUI page
/// draws it; tests snapshot ``outline``.
nonisolated public struct WhatsNewPageContent: Equatable, Sendable {
    public var sections: [Section]

    public struct Section: Equatable, Sendable, Identifiable {
        public var id: String { version }
        public var version: String
        /// "cmux 0.66.0" or "cmux Nightly 1.0.0-nightly.42".
        public var title: String
        public var date: String
        public var headline: String
        public var groups: [Group]
        public var origin: WhatsNewDocument.Origin
    }

    public struct Group: Equatable, Sendable, Identifiable {
        public var id: String { category.rawValue }
        public var category: WhatsNewDocument.Category
        public var title: String
        public var rows: [Row]
    }

    public struct Row: Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var summary: String
        public var media: WhatsNewDocument.Media?
        public var mediaAlt: String?
        /// The try-it target, only when this build may run it.
        public var tryIt: WhatsNewDocument.TryIt?
        public var docs: URL?
        /// "For teams" / "For enterprise"; nil for everyone.
        public var audience: String?
    }

    /// - Parameters:
    ///   - languages: preferred languages, most preferred first.
    ///   - canTry: whether this build may run an entry's try-it target
    ///     (feed documents: only allow-listed actions).
    public init(documents: [WhatsNewDocument], languages: [String] = Locale.preferredLanguages,
                canTry: (WhatsNewDocument.TryIt, WhatsNewDocument.Origin) -> Bool = { _, _ in true }) {
        sections = documents.map { document in
            let groups = WhatsNewDocument.Category.allCases.compactMap { category -> Group? in
                let rows = document.entries.filter { $0.category == category }.map { entry in
                    Row(id: entry.id, title: entry.title.resolved(for: languages), summary: entry.summary.resolved(for: languages),
                        media: entry.media, mediaAlt: entry.media?.alt.resolved(for: languages),
                        tryIt: entry.tryIt.flatMap { canTry($0, document.origin) ? $0 : nil }, docs: entry.docs,
                        audience: WhatsNewStrings.audience(entry.audience))
                }
                return rows.isEmpty ? nil : Group(category: category, title: WhatsNewStrings.category(category), rows: rows)
            }
            return Section(version: document.version, title: WhatsNewStrings.versionTitle(document), date: document.date,
                           headline: document.headline.resolved(for: languages), groups: groups, origin: document.origin)
        }
    }

    public var isEmpty: Bool { sections.isEmpty }

    /// A text snapshot of the page: what a reader sees, in order.
    public var outline: String {
        var lines: [String] = []
        for section in sections {
            lines.append("# \(section.title) (\(section.date))")
            lines.append(section.headline)
            for group in section.groups {
                lines.append("## \(group.title)")
                for row in group.rows {
                    var line = "- \(row.title): \(row.summary)"
                    if row.media != nil { line += " [media]" }
                    if let audience = row.audience { line += " [\(audience)]" }
                    if row.tryIt != nil { line += " [\(WhatsNewStrings.tryIt)]" }
                    if row.docs != nil { line += " [\(WhatsNewStrings.learnMore)]" }
                    lines.append(line)
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}
