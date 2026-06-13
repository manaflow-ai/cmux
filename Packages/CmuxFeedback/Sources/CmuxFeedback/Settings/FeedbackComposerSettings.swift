public import Foundation

/// Static configuration for the feedback composer: the persisted-email defaults
/// key, the upload endpoint (env-overridable), size limits, and the founders
/// fallback address. Values are byte-identical to the originals lifted from the
/// app's `ContentView`.
public enum FeedbackComposerSettings {
    public static let storedEmailKey = "sidebarHelpFeedbackEmail"
    public static let endpointEnvironmentKey = "CMUX_FEEDBACK_API_URL"
    public static let defaultEndpoint = "https://cmux.com/api/feedback"
    public static let foundersEmail = "founders@manaflow.com"
    public static let maxMessageLength = 4_000
    public static let maxAttachmentCount = 10
    // Keep the multipart body below Vercel's 4.5 MB request limit.
    public static let maxTotalAttachmentBytes = 4 * 1_024 * 1_024
    public static let targetTotalAttachmentUploadBytes = 3_500_000

    /// Resolves the feedback endpoint, honoring the `CMUX_FEEDBACK_API_URL`
    /// environment override and falling back to the production endpoint.
    public static func endpointURL() -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let override = env[endpointEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(string: override)
        }
        return URL(string: defaultEndpoint)
    }
}
