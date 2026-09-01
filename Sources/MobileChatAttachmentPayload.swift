import Foundation

/// One mobile-chat attachment after RPC validation and before materialization.
struct MobileChatAttachmentPayload: Sendable {
    let encodedData: String
    let fileExtension: String
}

/// Tracks materialized mobile-chat files until the corresponding prompt hook
/// proves that the agent consumed them or the bounded fallback expires.
struct MobileChatAttachmentDelivery: Sendable {
    let id: UUID
    let workspaceID: UUID
    let surfaceID: UUID
    let promptText: String
    let fileURLs: [URL]
}
