/// One mobile-chat image attachment after untyped RPC decoding and before
/// concurrent Base64 decoding and file materialization.
struct MobileChatAttachmentPayload: Sendable {
    let encodedData: String
    let fileExtension: String
}
