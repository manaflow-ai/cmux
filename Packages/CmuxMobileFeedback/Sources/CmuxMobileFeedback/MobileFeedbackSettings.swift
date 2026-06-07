#if os(iOS)
import Foundation

/// Runtime configuration and limits for mobile feedback submission.
public struct MobileFeedbackSettings: Sendable {
    /// Environment variable that overrides the feedback API endpoint in dev builds.
    public static let endpointEnvironmentKey = "CMUX_FEEDBACK_API_URL"
    /// Production feedback API endpoint used when no override is present.
    public static let defaultEndpoint = "https://cmux.com/api/feedback"
    /// Maximum message body length accepted by the mobile feedback form.
    public static let maxMessageLength = 4_000
    /// Maximum number of optional photo attachments accepted by the form.
    public static let maxPhotoAttachmentCount = 10
    /// Maximum diagnostics text bytes sent as the feedback diagnostics file.
    public static let maxDiagnosticsAttachmentBytes = 512 * 1_024
    /// Target aggregate byte budget for prepared photo attachments.
    public static let targetTotalPhotoUploadBytes = 3_300_000

    /// Feedback API endpoint URL.
    public let endpointURL: URL

    /// Creates settings for a concrete endpoint URL.
    ///
    /// - Parameter endpointURL: The feedback API endpoint to submit to.
    public init(endpointURL: URL) {
        self.endpointURL = endpointURL
    }

    /// Resolves live settings from process environment or the production default.
    ///
    /// - Returns: Settings when the configured endpoint is a valid URL.
    public static func live() -> MobileFeedbackSettings? {
        let env = ProcessInfo.processInfo.environment
        if let override = env[endpointEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           override.isEmpty == false {
            guard let url = URL(string: override) else { return nil }
            return MobileFeedbackSettings(endpointURL: url)
        }
        guard let url = URL(string: defaultEndpoint) else { return nil }
        return MobileFeedbackSettings(endpointURL: url)
    }
}
#endif
