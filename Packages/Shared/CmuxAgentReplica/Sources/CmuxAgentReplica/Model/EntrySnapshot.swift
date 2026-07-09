import Foundation

/// Captures one replaceable transcript entry value.
public struct EntrySnapshot: Codable, Hashable, Sendable {
    /// The journal that owns this entry.
    public let journalID: JournalID
    /// The sequence number within the journal.
    public let seq: EntrySeq
    /// The entry kind.
    public let kind: EntryKind
    /// The opaque content for this slice.
    public let content: EntryContent
    /// The entity version for this entry in the current epoch.
    public let version: EntityVersion

    /// Creates an entry snapshot.
    /// - Parameters:
    ///   - journalID: The owning journal identifier.
    ///   - seq: The journal-local sequence.
    ///   - kind: The entry kind.
    ///   - content: The opaque content.
    ///   - version: The entity version in the current epoch.
    public init(journalID: JournalID, seq: EntrySeq, kind: EntryKind, content: EntryContent, version: EntityVersion) {
        self.journalID = journalID
        self.seq = seq
        self.kind = kind
        self.content = content
        self.version = version
    }
}
