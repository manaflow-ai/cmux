public import CmuxAgentReplica
import Foundation

/// Captures one incremental transcript decoder output batch.
public struct TranscriptDecodeBatch: Hashable, Sendable {
    /// The decoded entries emitted by this batch.
    public let entries: [EntrySnapshot]
    /// Diagnostics emitted by this batch.
    public let diagnostics: TranscriptDecoderDiagnostics

    /// Creates a transcript decode batch.
    /// - Parameters:
    ///   - entries: Decoded entries.
    ///   - diagnostics: Decoder diagnostics.
    public init(
        entries: [EntrySnapshot],
        diagnostics: TranscriptDecoderDiagnostics
    ) {
        self.entries = entries
        self.diagnostics = diagnostics
    }
}
