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
    /// The full notes (a harness's published changelog), when there is a page for them: the item's
    /// context link (the Feed shows the body as plain text, so it holds no Markdown link).
    public var notes: URL?

    /// Changes not in ``changes`` that the card counts with the rest (a record that kept only the
    /// top items and their total).
    public var unlisted: Int
    public var at: Date

    /// How many changes the card lists.
    public static let maxChanges = 5

    public init(subject: Subject, from: String?, to: String, changes: [String], unlisted: Int = 0, notes: URL? = nil, at: Date) {
        self.subject = subject
        self.from = from
        self.to = to
        self.changes = changes
        self.unlisted = max(0, unlisted)
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
        guard let range = version.range(of: "-nightly.") else { return version }
        let build = version[range.upperBound...]
        guard !build.isEmpty, build.allSatisfy(\.isNumber) else { return version }
        return "nightly " + String(build.prefix(7))
    }

    /// The card's text: where it came from, the top changes as bullets and how many more.
    public var body: String {
        var lines: [String] = []
        if let from, from != to { lines.append(FeedStrings.updatedFrom(Self.readable(from))) }
        let shown = changes.prefix(Self.maxChanges)
        if !shown.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines += shown.map { "- " + Self.oneLine($0) }
        }
        let more = changes.count - shown.count + unlisted
        if more > 0 { lines.append(FeedStrings.moreChanges(more)) }
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
            dedupeKey: dedupeKey, thread: thread, context: FeedContext(url: notes?.scheme == "https" ? notes : nil),
            poster: FeedPoster(kind: subject == .app ? .app : .harness, label: name), createdAt: at)
    }

    /// A change on its first line without a list marker (a changelog line can hold a nested list);
    /// emphasis such as `**Bold**` stays.
    static func oneLine(_ text: String) -> String {
        var line = (text.split(whereSeparator: \.isNewline).first ?? "").drop { $0 == " " }
        // Each pass drops one marker and the line gets shorter, so it ends.
        while line.count >= 2, line.first == "-" || line.first == "*", line.dropFirst().first == " " {
            line = line.dropFirst(2).drop { $0 == " " }
        }
        return String(line)
    }

    static func stableID(_ key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return "fi_" + digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }
}
