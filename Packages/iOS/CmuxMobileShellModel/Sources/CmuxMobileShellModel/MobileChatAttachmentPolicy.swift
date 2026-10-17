/// Wire-size limits for inline chat attachments.
///
/// Chat attachments travel together in one JSON-RPC request, so this budget is
/// deliberately smaller than the staged terminal/task attachment budgets that
/// upload each image separately.
public struct MobileChatAttachmentPolicy: Sendable {
    public init() {}

    /// Maximum number of images in one chat message.
    public let maximumCount: Int = 4
    /// Maximum encoded image bytes across the complete chat request.
    /// Base64 expansion and request metadata keep the resulting frame below the
    /// mobile control transport's roughly 8 MiB ceiling.
    public let maximumTotalBytes: Int = 4 * 1024 * 1024
    /// Maximum UTF-8 prompt size in one chat request. This leaves room for
    /// the JSON envelope when the attachment budget is also full.
    public let maximumTextBytes: Int = 2 * 1024 * 1024
}
