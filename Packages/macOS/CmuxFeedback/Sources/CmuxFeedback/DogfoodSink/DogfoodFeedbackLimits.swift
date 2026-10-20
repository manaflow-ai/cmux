import Foundation

/// Hard caps for the agent feedback sink. The only intended caller is a
/// paired phone, but a malformed or hostile request must not be able to
/// allocate huge buffers, block the Mac UI, or grow the cache without bound.
/// Strings are capped by character count before any large allocation; the
/// base64 blob is rejected outright past its cap (so it is never decoded),
/// and a decoded blob past the byte cap is dropped.
public struct DogfoodFeedbackLimits: Sendable, Equatable {
    /// Maximum number of characters retained from the free-form `text` field.
    public var maxTextChars: Int
    /// Maximum number of characters retained from the captured `terminal_text`.
    public var maxTerminalChars: Int
    /// Maximum number of characters retained from the `build_stamp` field.
    public var maxBuildStampChars: Int
    /// Maximum length of the base64-encoded diagnostic blob string. A request
    /// past this is rejected without ever decoding the blob into a `Data`.
    public var maxBlobBase64Chars: Int
    /// Maximum size in bytes of the decoded diagnostic blob. A decoded blob
    /// past this is dropped.
    public var maxBlobBytes: Int
    /// Keep at most this many bundle directories; older ones are pruned after
    /// each write so a retrying client can't grow the cache without bound.
    public var maxRetainedBundles: Int

    /// Create an explicit set of feedback sink caps.
    /// - Parameters:
    ///   - maxTextChars: cap on the free-form `text` field.
    ///   - maxTerminalChars: cap on the captured `terminal_text` field.
    ///   - maxBuildStampChars: cap on the `build_stamp` field.
    ///   - maxBlobBase64Chars: cap on the base64 blob string length.
    ///   - maxBlobBytes: cap on the decoded blob size.
    ///   - maxRetainedBundles: how many bundle directories to retain.
    public init(
        maxTextChars: Int,
        maxTerminalChars: Int,
        maxBuildStampChars: Int,
        maxBlobBase64Chars: Int,
        maxBlobBytes: Int,
        maxRetainedBundles: Int
    ) {
        self.maxTextChars = maxTextChars
        self.maxTerminalChars = maxTerminalChars
        self.maxBuildStampChars = maxBuildStampChars
        self.maxBlobBase64Chars = maxBlobBase64Chars
        self.maxBlobBytes = maxBlobBytes
        self.maxRetainedBundles = maxRetainedBundles
    }

    /// The production caps used by the macOS host feedback sink. These match
    /// the values that previously lived as static constants on the host's RPC
    /// router, byte for byte.
    public static let `default` = DogfoodFeedbackLimits(
        maxTextChars: 16_384,
        maxTerminalChars: 262_144,
        maxBuildStampChars: 512,
        maxBlobBase64Chars: 8_388_608, // ~6 MiB decoded
        maxBlobBytes: 6_291_456, // 6 MiB
        maxRetainedBundles: 50
    )
}
