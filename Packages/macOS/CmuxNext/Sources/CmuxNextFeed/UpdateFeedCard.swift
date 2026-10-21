import CryptoKit
public import Foundation

/// An installed update as a Feed notice (Leo 2026-10-20: "each installed update, the app nightly
/// and each agent CLI, posts a Feed card"): what was updated, from and to which version, its top
/// changes and where the full notes are. One shape for the app and for a harness, posted through
/// the local feed owner like GitHub's items (`FeedPostingSource.post`), so it never travels
/// through a cloud session and the owner's dedupe applies. The changes are the What's New items
/// the Updated card shows (`UpdateHighlights`) or the harness's published changelog lines.
public nonisolated struct UpdateFeedCard: Sendable, Equatable {
    /// What was updated.
    public enum Subject: Sendable, Equatable {
        /// cmux itself.
        case app
        /// An agent CLI by its acpmux harness id, with the name people see ("Claude Code").
        case harness(id: String, name: String)
    }

    public var subject: Subject
    /// The version before the update, when known.
    public var from: String?
    public var to: String
    /// The changes, most important first; the card lists ``maxChanges`` and counts the rest.
    public var changes: [String]
    /// The full notes (a harness's published changelog), when there is a page for them.
    public var notes: URL?
    public var at: Date

    /// How many changes the card lists.
    public static let maxChanges = 5

    public init(subject: Subject, from: String?, to: String, changes: [String], notes: URL? = nil, at: Date) {
        self.subject = subject
        self.from = from
        self.to = to
        self.changes = changes
        self.notes = notes
        self.at = at
    }

    /// One card per installed version: `update:app:<to>` or `update:harness:<id>:<to>`.
    public var dedupeKey: String {
        switch subject {
        case .app: "update:app:\(to)"
        case let .harness(id, _): "update:harness:\(id):\(to)"
        }
    }

    /// The name of what was updated.
    public var name: String {
        switch subject {
        case .app: "cmux"
        case let .harness(_, name): name
        }
    }

    /// "1.0.0-nightly.3947430561301" reads "nightly 3947430", as the Update Ready card; any other
    /// version reads as itself.
    public static func readable(_ version: String) -> String {
        guard let range = version.range(of: "-nightly."), version[range.upperBound...].allSatisfy(\.isNumber) else { return version }
        return "nightly " + String(version[range.upperBound...].prefix(7))
    }

    /// The card's Markdown: where it came from, the top changes as bullets, how many more, and
    /// the full notes' link.
    public var body: String {
        var lines: [String] = []
        if let from, from != to { lines.append(FeedStrings.updatedFrom(Self.readable(from))) }
        let shown = changes.prefix(Self.maxChanges)
        if !shown.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines += shown.map { "- " + Self.oneLine($0) }
        }
        if changes.count > shown.count { lines.append(FeedStrings.moreChanges(changes.count - shown.count)) }
        if let notes, notes.scheme == "https" {
            lines.append("")
            lines.append("[\(FeedStrings.fullNotes)](\(notes.absoluteString))")
        }
        return String(lines.joined(separator: "\n").prefix(4096))
    }

    /// The Feed notice: a local integration item, normal priority, threaded per subject.
    public var item: FeedItem {
        let thread = switch subject {
        case .app: "update:app"
        case let .harness(id, _): "update:harness:\(id)"
        }
        return FeedItem(
            id: Self.stableID(dedupeKey), home: .local(install: "updates"),
            title: FeedStrings.updatedTo(name, Self.readable(to)), body: body, prompt: .notice, priority: .normal,
            dedupeKey: dedupeKey, thread: thread, context: FeedContext(url: notes),
            poster: FeedPoster(kind: subject == .app ? .app : .harness, label: name), createdAt: at)
    }

    /// A change on one line, Markdown list syntax and all (a changelog line can hold a nested list).
    static func oneLine(_ text: String) -> String {
        var line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        while let first = line.first, first == "-" || first == "*" || first == " " { line.removeFirst() }
        return line
    }

    static func stableID(_ key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return "fi_" + digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }
}
