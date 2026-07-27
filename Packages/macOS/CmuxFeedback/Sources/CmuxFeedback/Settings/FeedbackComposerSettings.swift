public import Foundation

/// Configuration value for the feedback composer: the persisted-email defaults
/// key, the upload endpoint (env-overridable), size limits, and the founders
/// fallback address. Defaults are byte-identical to the originals lifted from
/// the app's `ContentView`; construct with the defaults or override a field for
/// testing.
public struct FeedbackComposerSettings: Sendable, Equatable {
    /// `UserDefaults` key the composer persists the submitter's email under.
    public let storedEmailKey: String
    /// Environment variable name that overrides the upload endpoint.
    public let endpointEnvironmentKey: String
    /// Production feedback upload endpoint used when no override is set.
    public let defaultEndpoint: String
    /// Fallback contact address surfaced when uploads are unavailable.
    public let foundersEmail: String
    /// Maximum accepted message length, in characters.
    public let maxMessageLength: Int
    /// Maximum number of image attachments per submission.
    public let maxAttachmentCount: Int
    /// Hard cap on the multipart body size (kept below Vercel's 4.5 MB limit).
    public let maxTotalAttachmentBytes: Int
    /// Target total attachment payload after optimization, in bytes.
    public let targetTotalAttachmentUploadBytes: Int

    /// Creates the feedback settings, defaulting every field to the production
    /// value lifted verbatim from `ContentView`.
    public init(
        storedEmailKey: String = "sidebarHelpFeedbackEmail",
        endpointEnvironmentKey: String = "CMUX_FEEDBACK_API_URL",
        defaultEndpoint: String = "https://cmux.com/api/feedback",
        foundersEmail: String = "founders@manaflow.com",
        maxMessageLength: Int = 4_000,
        maxAttachmentCount: Int = 10,
        maxTotalAttachmentBytes: Int = 4 * 1_024 * 1_024,
        targetTotalAttachmentUploadBytes: Int = 3_500_000
    ) {
        self.storedEmailKey = storedEmailKey
        self.endpointEnvironmentKey = endpointEnvironmentKey
        self.defaultEndpoint = defaultEndpoint
        self.foundersEmail = foundersEmail
        self.maxMessageLength = maxMessageLength
        self.maxAttachmentCount = maxAttachmentCount
        self.maxTotalAttachmentBytes = maxTotalAttachmentBytes
        self.targetTotalAttachmentUploadBytes = targetTotalAttachmentUploadBytes
    }

    /// Resolves the feedback endpoint, honoring the `endpointEnvironmentKey`
    /// environment override and falling back to ``defaultEndpoint``.
    public func endpointURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let override = environment[endpointEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(string: override)
        }
        return URL(string: defaultEndpoint)
    }
}
