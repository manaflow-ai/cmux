internal import Foundation

/// Stable identity for one terminal attachment within a remote transport.
struct RemotePTYAttachmentKey: Hashable, Sendable {
    let transportKey: String
    let attachmentID: String

    init(transportKey: String, attachmentID: String) {
        self.transportKey = transportKey
        let trimmed = attachmentID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.attachmentID = UUID(uuidString: trimmed)?.uuidString.lowercased() ?? trimmed
    }
}
