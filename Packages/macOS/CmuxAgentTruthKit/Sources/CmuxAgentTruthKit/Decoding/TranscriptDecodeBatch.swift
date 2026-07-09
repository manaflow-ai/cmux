public import CmuxAgentReplica
import Foundation

/// Captures one incremental transcript decoder output batch.
public struct TranscriptDecodeBatch: Hashable, Sendable {
    /// The decoded entries emitted by this batch.
    public let entries: [EntrySnapshot]
    /// Rich decoded payloads keyed by journal and sequence.
    public let payloads: [EntryCoordinate: DecodedEntryPayload]
    /// Diagnostics emitted by this batch.
    public let diagnostics: TranscriptDecoderDiagnostics

    /// Creates a transcript decode batch.
    /// - Parameters:
    ///   - entries: Decoded entries.
    ///   - payloads: Rich payload side table.
    ///   - diagnostics: Decoder diagnostics.
    public init(
        entries: [EntrySnapshot],
        payloads: [EntryCoordinate: DecodedEntryPayload],
        diagnostics: TranscriptDecoderDiagnostics
    ) {
        self.entries = entries
        self.payloads = payloads
        self.diagnostics = diagnostics
    }
}
