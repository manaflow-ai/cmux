package import CmuxNextDaemon
import CryptoKit
package import Foundation

/// An installed update as a Feed notice (Leo 2026-10-20: "each installed update, the app nightly
/// and each agent CLI, posts a Feed card"): what was updated, from and to which version, its top
/// changes and where the full notes are. One shape for the app and for a harness, posted through
/// the daemon's integration owner like GitHub's items (`feed.post`), so it never travels
/// through a cloud session and the owner's dedupe applies. The changes are the What's New items
/// the Updated card shows (`UpdateHighlights`) or the harness's published changelog lines.
package nonisolated struct UpdateFeedCard: Sendable, Equatable {
    /// What was updated.
    package enum Subject: Sendable, Equatable {
        /// cmux itself.
        case app
        /// An agent CLI by its acpmux harness id, with the name people see ("Claude Code").
        case harness(id: String, name: String)
    }

    package var subject: Subject
    /// The version before the update, when known.
    package var from: String?
    package var to: String
    /// The changes, most important first; the card lists ``maxChanges`` and counts the rest.
    package var changes: [String]
    /// The full notes (a harness's published changelog), when there is a page for them: the item's
    /// context link (the Feed shows the body as plain text, so it holds no Markdown link).
    package var notes: URL?

    /// Changes not in ``changes`` that the card counts with the rest (a record that kept only the
    /// top items and their total).
    package var unlisted: Int
    package var at: Date

    /// How many changes the card lists.
    package static let maxChanges = 5

    package init(subject: Subject, from: String?, to: String, changes: [String], unlisted: Int = 0, notes: URL? = nil, at: Date) {
        self.subject = subject
        self.from = from
        self.to = to
        self.changes = changes
        self.unlisted = max(0, unlisted)
        self.notes = notes
        self.at = at
    }

    /// One card per installed version: `update:app:<to>` or `update:harness:<id>:<to>`.
    package var dedupeKey: String {
        switch subject {
        case .app: "update:app:\(to)"
        case let .harness(id, _): "update:harness:\(id):\(to)"
        }
    }

    /// The name of what was updated.
    package var name: String {
        switch subject {
        case .app: "cmux"
        case let .harness(_, name): name
        }
    }

    /// "1.0.0-nightly.3947430561301" reads "nightly 3947430", as the Update Ready card; any other
    /// version reads as itself.
    package static func readable(_ version: String) -> String {
        guard let range = version.range(of: "-nightly.") else { return version }
        let build = version[range.upperBound...]
        guard !build.isEmpty, build.allSatisfy(\.isNumber) else { return version }
        return "nightly " + String(build.prefix(7))
    }

    /// The card's text: where it came from, the top changes as bullets and how many more.
    package var body: String {
        var lines: [String] = []
        if let from, from != to { lines.append(Self.t("update.from", "From \(Self.readable(from))")) }
        let shown = changes.prefix(Self.maxChanges)
        if !shown.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines += shown.map { "- " + Self.oneLine($0) }
        }
        let more = changes.count - shown.count + unlisted
        if more > 0 { lines.append(Self.t("update.moreChanges", "\(more) more changes")) }
        return String(lines.joined(separator: "\n").prefix(4096))
    }

    /// The Feed notice as `feed.post`'s item (FeedDO wire shape): a local integration item, normal
    /// priority, threaded per subject.
    package var item: [String: JSONValue] {
        let thread = switch subject {
        case .app: "update:app"
        case let .harness(id, _): "update:harness:\(id)"
        }
        let ms = JSONValue.number((at.timeIntervalSince1970 * 1000).rounded())
        var context: [String: JSONValue] = [:]
        if let notes, notes.scheme == "https" { context["url"] = .string(notes.absoluteString) }
        return [
            "id": .string(Self.stableID(dedupeKey)), "home": .string("local:updates"), "type": .string("notice"), "kind": .string("notice"),
            "title": .string(Self.t("update.updatedTo", "\(name) updated to \(Self.readable(to))")), "body": .string(body),
            "priority": .string("normal"), "dedupe_key": .string(dedupeKey), "thread": .string(thread), "context": .object(context),
            "poster": .object(["kind": .string(subject == .app ? "app" : "harness"), "label": .string(name)]),
            "state": .string("open"), "count": .number(1), "revision": .number(1), "created_at": ms, "updated_at": ms,
        ]
    }

    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }

    /// A change on its first line without a list marker (a changelog line can hold a nested list);
    /// emphasis such as `**Bold**` stays.
    package static func oneLine(_ text: String) -> String {
        var line = (text.split(whereSeparator: \.isNewline).first ?? "").drop { $0 == " " }
        // Each pass drops one marker and the line gets shorter, so it ends.
        while line.count >= 2, line.first == "-" || line.first == "*", line.dropFirst().first == " " {
            line = line.dropFirst(2).drop { $0 == " " }
        }
        return String(line)
    }

    package static func stableID(_ key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return "fi_" + digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }
}
