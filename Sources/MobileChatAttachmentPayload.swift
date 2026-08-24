/// One mobile-chat attachment after RPC validation and before materialization.
struct MobileChatAttachmentPayload: Sendable {
    let encodedData: String
    let fileExtension: String
}
