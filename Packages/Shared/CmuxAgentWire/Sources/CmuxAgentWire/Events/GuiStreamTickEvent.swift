public import CmuxAgentReplica

/// Ephemeral streaming-preview payload for one journal.
public struct GuiStreamTickEvent: Codable, Hashable, Sendable {
    /// The maximum UTF-8 byte count retained for ``textTail``.
    public static let textTailByteLimit = 16 * 1_024

    /// The journal receiving the preview.
    public let journalID: JournalID
    /// The committed sequence after which this preview belongs.
    public let afterSeq: EntrySeq
    /// A bounded trailing text preview.
    public let textTail: String
    /// The preview revision within the current stream.
    public let revision: Int

    private enum CodingKeys: String, CodingKey {
        case journalID = "journal_id"
        case afterSeq = "after_seq"
        case textTail = "text_tail"
        case revision
    }

    /// Creates a stream-tick payload, retaining at most the trailing 16 KB of text.
    /// - Parameters:
    ///   - journalID: The journal receiving the preview.
    ///   - afterSeq: The committed sequence before the preview.
    ///   - textTail: The trailing text preview.
    ///   - revision: The stream revision.
    public init(journalID: JournalID, afterSeq: EntrySeq, textTail: String, revision: Int) {
        self.journalID = journalID
        self.afterSeq = afterSeq
        self.textTail = Self.truncatedTail(textTail)
        self.revision = revision
    }

    /// Decodes a stream tick while enforcing the 16 KB preview bound.
    /// - Parameter decoder: The decoder to read from.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.journalID = try container.decode(JournalID.self, forKey: .journalID)
        self.afterSeq = try container.decode(EntrySeq.self, forKey: .afterSeq)
        self.textTail = Self.truncatedTail(try container.decode(String.self, forKey: .textTail))
        self.revision = try container.decode(Int.self, forKey: .revision)
    }

    private static func truncatedTail(_ value: String) -> String {
        guard value.utf8.count > textTailByteLimit else {
            return value
        }
        var bytes = Array(value.utf8.suffix(textTailByteLimit))
        while let first = bytes.first, first & 0b1100_0000 == 0b1000_0000 {
            bytes.removeFirst()
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
