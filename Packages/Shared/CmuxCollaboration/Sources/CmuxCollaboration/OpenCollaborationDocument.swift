import Foundation

/// Local state for one open shared file.
struct OpenCollaborationDocument: Sendable {
    let file: SharedFileDescriptor
    var document: CollaborationTextDocument
    let baselineHash: String
    var lastWrittenHash: String?

    var snapshot: CollaborationDocumentSnapshot {
        let text = document.text
        return CollaborationDocumentSnapshot(
            documentID: file.documentID(sessionID: ""),
            text: text,
            textHash: TextHash().hash(text)
        )
    }
}
