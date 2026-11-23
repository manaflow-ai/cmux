import Foundation

extension AgentPaneDictation {
    static var openSettingsTitle: String {
        String(localized: "agentPane.dictation.openSettings", defaultValue: "Open System Settings", bundle: .localizedModule)
    }

    /// What the person's own dictation provider (`agentPane.dictationEngine`) answered, by acpmux's
    /// `_acpmux/voice/transcribe` error code; `detail` is the provider's own short message, shown only
    /// for a refused request.
    static func providerFailureMessage(code: String, detail: String) -> String {
        switch code {
        case "key_missing":
            String(localized: "agentPane.dictation.provider.keyMissing", defaultValue: "Dictation needs an API key. Add it in Settings > Agent Chat.", bundle: .localizedModule)
        case "key_invalid":
            String(localized: "agentPane.dictation.provider.keyInvalid", defaultValue: "The dictation service refused the API key. Check it in Settings > Agent Chat.", bundle: .localizedModule)
        case "offline":
            String(localized: "agentPane.dictation.provider.offline", defaultValue: "Could not reach the dictation service. Check the connection, or switch Dictation Engine to On This Mac.", bundle: .localizedModule)
        case "timeout":
            String(localized: "agentPane.dictation.provider.timeout", defaultValue: "The dictation service took too long to answer. Try again.", bundle: .localizedModule)
        case "rate_limited":
            String(localized: "agentPane.dictation.provider.rateLimited", defaultValue: "The dictation service is busy or over its limit. Try again in a moment.", bundle: .localizedModule)
        case "bad_endpoint":
            String(localized: "agentPane.dictation.provider.badEndpoint", defaultValue: "The dictation server URL is not usable. Check it in Settings > Agent Chat.", bundle: .localizedModule)
        case "rejected" where detail.isEmpty:
            String(localized: "agentPane.dictation.provider.rejected", defaultValue: "The dictation service refused the recording.", bundle: .localizedModule)
        case "rejected":
            String(format: String(localized: "agentPane.dictation.provider.rejectedDetail", defaultValue: "The dictation service refused the recording: %@", bundle: .localizedModule), detail)
        case "too_large":
            String(localized: "agentPane.dictation.provider.tooLarge", defaultValue: "That recording is too long for the dictation service.", bundle: .localizedModule)
        case "provider_error", "bad_response":
            String(localized: "agentPane.dictation.provider.providerError", defaultValue: "The dictation service had a problem. Try again.", bundle: .localizedModule)
        default:
            String(localized: "agentPane.dictation.provider.failed", defaultValue: "Dictation failed. Check Dictation Engine in Settings > Agent Chat.", bundle: .localizedModule)
        }
    }
}
