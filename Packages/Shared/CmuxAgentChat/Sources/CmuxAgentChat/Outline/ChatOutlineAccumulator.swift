import Foundation

/// Incrementally reduces parsed transcript messages to one outline entry per
/// user prompt.
///
/// Feed it message batches in ascending transcript order (a backfill, then
/// each live batch). A prompt line that yields several user messages (leading
/// attachments, then prose) becomes one entry titled by its prose. The first
/// agent prose after a prompt becomes that entry's reply preview.
public struct ChatOutlineAccumulator: Sendable {
    /// Transcript user lines that are not prompts the person typed to the
    /// agent: interruption markers, shell-mode echoes and compaction
    /// summaries.
    private static let nonPromptPrefixes = [
        "[Request interrupted by user",
        "<bash-input>",
        "<bash-stdout>",
        "<bash-stderr>",
        "This session is being continued from a previous conversation",
    ]

    /// Most recent entries kept; older ones fall off the front.
    public let maxEntries: Int
    /// Entries, oldest first.
    public private(set) var entries: [ChatOutlineEntry] = []
    /// Whether older prompts exist that this outline no longer (or never)
    /// held.
    public private(set) var isHeadTruncated = false

    private var lastIngestedSeq = -1
    private var lastEntryTitledByAttachment = false

    /// Creates an empty accumulator.
    ///
    /// - Parameter maxEntries: Cap on retained entries.
    public init(maxEntries: Int = 5_000) {
        self.maxEntries = max(1, maxEntries)
    }

    /// Clears all entries (the transcript was replaced).
    public mutating func reset() {
        entries = []
        isHeadTruncated = false
        lastIngestedSeq = -1
        lastEntryTitledByAttachment = false
    }

    /// Records that transcript lines before the first ingested batch were
    /// skipped, so earlier prompts are missing.
    public mutating func markHeadTruncated() {
        isHeadTruncated = true
    }

    /// Folds newly parsed messages into the outline.
    ///
    /// Messages at or before the last ingested line are ignored, so a batch
    /// that overlaps an earlier one is harmless.
    ///
    /// - Parameter messages: Messages in ascending `seq` order.
    public mutating func ingest(_ messages: some Sequence<ChatMessage>) {
        var batchMaxSeq = lastIngestedSeq
        for message in messages where message.seq > lastIngestedSeq {
            batchMaxSeq = max(batchMaxSeq, message.seq)
            switch message.role {
            case .user:
                ingestUser(message)
            case .agent:
                ingestAgent(message)
            case .system:
                continue
            }
        }
        lastIngestedSeq = batchMaxSeq
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
            isHeadTruncated = true
        }
    }

    private mutating func ingestUser(_ message: ChatMessage) {
        let text: String
        let isAttachment: Bool
        switch message.kind {
        case .prose(let prose):
            text = prose.text
            isAttachment = false
        case .attachment(let attachment):
            guard let name = attachment.displayName else { return }
            text = name
            isAttachment = true
        default:
            return
        }
        let title = Self.firstLine(of: text, limit: ChatOutlineEntry.titleLimit)
        guard !title.isEmpty else { return }
        if !isAttachment, Self.nonPromptPrefixes.contains(where: { title.hasPrefix($0) }) {
            return
        }
        if let last = entries.last, last.seq == message.seq {
            // Same prompt line: prose wins over an attachment name.
            if lastEntryTitledByAttachment, !isAttachment {
                entries[entries.count - 1] = last.withTitle(title)
                lastEntryTitledByAttachment = false
            }
            return
        }
        entries.append(ChatOutlineEntry(
            id: message.id,
            seq: message.seq,
            timestamp: message.timestamp,
            title: title
        ))
        lastEntryTitledByAttachment = isAttachment
    }

    private mutating func ingestAgent(_ message: ChatMessage) {
        guard case .prose(let prose) = message.kind,
              let last = entries.last,
              last.replyPreview == nil,
              message.seq > last.seq else {
            return
        }
        let preview = Self.leadingLines(of: prose.text, count: 2, limit: ChatOutlineEntry.replyPreviewLimit)
        guard !preview.isEmpty else { return }
        entries[entries.count - 1] = last.withReplyPreview(preview)
    }

    static func firstLine(of text: String, limit: Int) -> String {
        leadingLines(of: text, count: 1, limit: limit)
    }

    /// The first `count` non-empty lines, each whitespace-collapsed, joined
    /// by a space and clipped to `limit` characters.
    static func leadingLines(of text: String, count: Int, limit: Int) -> String {
        var lines: [String] = []
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let collapsed = rawLine
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .joined(separator: " ")
            guard !collapsed.isEmpty else { continue }
            lines.append(collapsed)
            if lines.count == count { break }
        }
        return String(lines.joined(separator: " ").prefix(limit))
    }
}
