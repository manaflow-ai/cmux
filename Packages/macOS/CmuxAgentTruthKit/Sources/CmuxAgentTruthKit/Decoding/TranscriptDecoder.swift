public import CmuxAgentReplica
import Foundation

/// Incrementally decodes agent transcript JSONL into journal entries.
public protocol TranscriptDecoder {
    /// Feeds transcript lines at their absolute line index.
    /// - Parameters:
    ///   - lines: The raw JSONL lines.
    ///   - startingAt: The absolute line index for the first line.
    ///   - journalID: The journal id that owns emitted entries.
    /// - Returns: The entries, payload side table, and decoder diagnostics emitted by this feed.
    mutating func feed(_ lines: [String], startingAt: Int, journalID: JournalID) -> TranscriptDecodeBatch
}
