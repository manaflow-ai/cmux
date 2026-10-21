import CmuxMobileArtifacts
import Foundation

/// `@` file mentions in the composer, as the Mac's acpmux composer writes
/// them (`MentionMenu.tsx`): typing `@query` at the end of the text offers
/// files, and picking one writes `@path ` (quoted when the path has a space).
/// The phone has no file-search channel over the link yet, so candidates are
/// the files this session already referenced (edited, read, attached,
/// mentioned), strongest first.
public struct ComposerMention: Hashable, Sendable {
    /// Where the `@` is.
    public var start: String.Index
    /// What follows it.
    public var query: String

    /// The mention being typed at the end of `text`, if any: an `@` at the
    /// start or after whitespace, not inside a code span.
    public init?(text: String) {
        guard let at = text.lastIndex(of: "@") else { return nil }
        let query = text[text.index(after: at)...]
        guard !query.contains(where: \.isWhitespace), !query.contains("@") else { return nil }
        if at > text.startIndex, !text[text.index(before: at)].isWhitespace { return nil }
        if text[..<at].filter({ $0 == "`" }).count % 2 == 1 { return nil }
        self.start = at
        self.query = String(query)
    }

    /// `text` with this mention replaced by `@path `.
    public func inserting(_ path: String, into text: String) -> String {
        String(text[..<start]) + Self.text(for: path)
    }

    /// `@path ` (quoted when the path has a space; an agent reads a mention up to the first one).
    public static func text(for path: String) -> String {
        "@\(path.contains(where: \.isWhitespace) ? "\"\(path)\"" : path) "
    }

    /// Files and folders among `artifacts` matching `query`: name prefix
    /// first, then name, then path containing it; at most `limit`.
    public static func candidates(_ query: String, in artifacts: [TerminalArtifact], limit: Int = 6) -> [TerminalArtifact] {
        let files = artifacts.filter { $0.kind != .link && !$0.reference.hasPrefix("Attachments/") }
        let needle = query.lowercased()
        guard !needle.isEmpty else { return Array(files.prefix(limit)) }
        func rank(_ artifact: TerminalArtifact) -> Int? {
            let name = artifact.name.lowercased()
            if name.hasPrefix(needle) { return 0 }
            if name.contains(needle) { return 1 }
            if artifact.reference.lowercased().contains(needle) { return 2 }
            return nil
        }
        return files.enumerated()
            .compactMap { index, artifact in rank(artifact).map { (artifact, $0, index) } }
            .sorted { ($0.1, $0.2) < ($1.1, $1.2) }
            .prefix(limit)
            .map(\.0)
    }
}
