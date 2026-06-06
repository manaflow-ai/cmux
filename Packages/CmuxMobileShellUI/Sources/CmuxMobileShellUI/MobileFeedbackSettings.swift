import Foundation

struct MobileFeedbackSettings: Sendable {
    static let storedEmailKey = "mobileFeedbackEmail"
    static let endpointEnvironmentKey = "CMUX_FEEDBACK_API_URL"
    static let defaultEndpoint = "https://cmux.com/api/feedback"
    static let maxMessageLength = 4_000
    static let maxPhotoAttachmentCount = 10
    static let maxDiagnosticsAttachmentBytes = 512 * 1_024
    static let targetTotalPhotoUploadBytes = 3_300_000

    let endpointURL: URL

    static func live() -> MobileFeedbackSettings? {
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
