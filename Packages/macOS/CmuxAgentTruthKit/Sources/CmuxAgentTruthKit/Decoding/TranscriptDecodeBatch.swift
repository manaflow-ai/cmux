public import CmuxAgentReplica
import Foundation

/// Image bytes retained only for host-side transcript materialization.
///
/// This type deliberately does not conform to `Codable`: embedded image bytes
/// are a transient decoder side table and never enter the replica transport.
public struct TranscriptEmbeddedImage: Sendable {
    /// Journal that owns the attachment entry.
    public let journalID: JournalID
    /// Sequence of the retained attachment entry.
    public let entrySeq: EntrySeq
    /// Declared media type, when the transcript supplies one.
    public let mimeType: String?
    /// Original base64 image bytes, without a data-URL prefix.
    public let base64EncodedData: String

    /// Creates a transient embedded-image record.
    public init(
        journalID: JournalID,
        entrySeq: EntrySeq,
        mimeType: String?,
        base64EncodedData: String
    ) {
        self.journalID = journalID
        self.entrySeq = entrySeq
        self.mimeType = mimeType
        self.base64EncodedData = base64EncodedData
    }
}

struct TranscriptEmbeddedImageSource: Sendable {
    let mimeType: String?
    let base64EncodedData: String
}

/// Captures one incremental transcript decoder output batch.
public struct TranscriptDecodeBatch: Sendable {
    /// The decoded entries emitted by this batch.
    public let entries: [EntrySnapshot]
    /// Embedded image bytes keyed to retained attachment entries.
    public let embeddedImages: [TranscriptEmbeddedImage]
    /// Diagnostics emitted by this batch.
    public let diagnostics: TranscriptDecoderDiagnostics

    /// Creates a transcript decode batch.
    /// - Parameters:
    ///   - entries: Decoded entries.
    ///   - embeddedImages: Transient image bytes for host-side materialization.
    ///   - diagnostics: Decoder diagnostics.
    public init(
        entries: [EntrySnapshot],
        embeddedImages: [TranscriptEmbeddedImage] = [],
        diagnostics: TranscriptDecoderDiagnostics
    ) {
        self.entries = entries
        self.embeddedImages = embeddedImages
        self.diagnostics = diagnostics
    }
}
