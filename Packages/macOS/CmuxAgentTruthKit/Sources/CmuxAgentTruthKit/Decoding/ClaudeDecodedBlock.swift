import CmuxAgentReplica
import Foundation

struct ClaudeDecodedBlock: Sendable {
    let summary: String
    let payload: EntryPayload
    let embeddedImage: TranscriptEmbeddedImageSource?

    var kind: EntryKind {
        payload.kind
    }

    init(
        summary: String,
        payload: EntryPayload,
        embeddedImage: TranscriptEmbeddedImageSource? = nil
    ) {
        self.summary = summary
        self.payload = payload
        self.embeddedImage = embeddedImage
    }
}
