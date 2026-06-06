#if os(iOS)
import Foundation

public struct MobileFeedbackSettings: Sendable {
    public static let storedEmailKey = "mobileFeedbackEmail"
    public static let endpointEnvironmentKey = "CMUX_FEEDBACK_API_URL"
    public static let defaultEndpoint = "https://cmux.com/api/feedback"
    public static let maxMessageLength = 4_000
    public static let maxPhotoAttachmentCount = 10
    public static let maxDiagnosticsAttachmentBytes = 512 * 1_024
    public static let targetTotalPhotoUploadBytes = 3_300_000

    public let endpointURL: URL

    public init(endpointURL: URL) {
        self.endpointURL = endpointURL
    }

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
