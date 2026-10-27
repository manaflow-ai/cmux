import CmuxChief
import CmuxHomeCore
import Foundation
import MessagesLabHome

/// One-line conversation list previews for the Chief: Markdown flattened to
/// what the transcript shows, and a waiting approval said in plain words
/// ("Needs your approval: Start Codex in “Scratch”", ``ChiefListPreview``; "Waiting
/// for you" until that line is read) instead of the card's raw prompt ("Run `…`?").
struct ChiefPreviewText {
    /// `markdown` without its markers: inline code and fences, bold, italic and
    /// strike markers, links and images (their text kept), heading hashes,
    /// quote markers and bullets; lines joined with spaces, runs of white space
    /// collapsed. Pure: no catalog, no store.
    func plain(_ markdown: String) -> String {
        var lines: [String] = []
        for raw in markdown.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { continue }
            line = line.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^(>\s?)+"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^[-*+]\s+(\[[ xX]\]\s+)?"#, with: "", options: .regularExpression)
            if !line.isEmpty { lines.append(line) }
        }
        var text = lines.joined(separator: " ")
        let inline: [(String, String)] = [
            (#"!\[([^\]]*)\]\([^)]*\)"#, "$1"),          // ![alt](src)
            (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),           // [text](url)
            (#"<((?:https?|mailto):[^>\s]+)>"#, "$1"),   // <https://…>
            (#"`+([^`]+?)`+"#, "$1"),                    // `code`, ``code``
            (#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#, "$2"),   // **bold**, __bold__
            (#"~~(?=\S)(.+?)(?<=\S)~~"#, "$1"),          // ~~strike~~
            (#"(?<![\w*])\*(?=\S)([^*]+?)(?<=\S)\*(?![\w*])"#, "$1"), // *italic*
            (#"(?<![\w_])_(?=\S)([^_]+?)(?<=\S)_(?![\w_])"#, "$1"),   // _italic_
        ]
        for (pattern, template) in inline {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// The preview while an approval card waits: "Waiting for you", the transcript's own status
    /// line (the card says what it asks), never the typing dots.
    var waitingForYou: String {
        String(localized: "chief.preview.waitingForYou", defaultValue: "Waiting for you")
    }

    /// The newest message's waiting approval prompt, nil when it has none.
    func pendingApprovalPrompt(_ message: Message?) -> String? {
        guard let message, !message.isRetracted else { return nil }
        for case .approval(let ref) in message.parts where ref.decided == nil { return ref.prompt }
        return nil
    }
}

/// A conversation's list preview and the row state it was read at.
struct ChiefPreviewEntry: Equatable {
    /// What the row showed when the line was read: a change reads it again.
    struct Stamp: Hashable {
        var lastSeq: Seq
        var rev: Revision
        var last: Message?
        var working: Bool
    }

    var stamp: Stamp
    var line: ChiefListPreview.Line?
}

/// The conversation list's second line from the conversation's newest messages
/// (``ChiefListPreview``: a waiting approval, a running tool, else the newest bubble),
/// not only from the newest message, which is often a system row ("Saved to memory",
/// "Stopped") or a finished tool call.
extension ChiefService {
    /// How many of the newest messages a preview reads.
    static let previewTail = 40

    /// `row`'s preview line; nil while none is known (the list keeps its own fallback). A row
    /// whose state changed reads its conversation's newest messages again from the owner, off
    /// the list's pass, and the list reloads when the line lands (``previewGeneration``).
    func listPreview(for row: InboxRow) -> ChiefListPreview.Line? {
        _ = previewGeneration
        let stamp = ChiefPreviewEntry.Stamp(lastSeq: row.summary.lastSeq, rev: row.summary.rev,
                                            last: row.summary.lastMessage, working: isWorking(row.id))
        if let entry = previewLines[row.id], entry.stamp == stamp { return entry.line }
        readPreview(row.id, stamp: stamp)
        // Until the read lands: the last line read, else what the newest message alone says.
        if let known = previewLines[row.id]?.line { return known }
        return ChiefListPreview(messages: row.summary.lastMessage.map { [$0] } ?? [], me: me).line
    }

    private func readPreview(_ id: ConversationID, stamp: ChiefPreviewEntry.Stamp) {
        guard let owner, !previewReads.contains(id) else { return }
        previewReads.insert(id)
        let me = self.me
        // task-owner: one page read from the owner; ends with its reply
        Task { @MainActor [weak self] in
            let messages = try? await owner.previewMessages(of: id, tail: Self.previewTail)
            guard let self else { return }
            self.previewReads.remove(id)
            let line = messages.flatMap { ChiefListPreview(messages: $0, me: me).line }
            let entry = ChiefPreviewEntry(stamp: stamp, line: line)
            guard self.previewLines[id] != entry else { return }
            self.previewLines[id] = entry
            self.previewGeneration &+= 1
        }
    }
}
