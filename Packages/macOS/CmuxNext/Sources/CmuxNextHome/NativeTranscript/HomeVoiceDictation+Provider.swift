import Foundation

extension HomeVoiceDictation {
    /// What the person's own dictation provider (`agentPane.dictationEngine`) answered, by acpmux's
    /// `_acpmux/voice/transcribe` error code; `detail` is the provider's own short message, shown only
    /// for a refused request.
    static func providerFailureMessage(code: String, detail: String) -> String {
        switch code {
        case "key_missing":
            String(localized: "home.voice.provider.keyMissing", defaultValue: "Dictation needs an API key. Add it in Settings > Agent Chat.", bundle: .localizedModule)
        case "key_invalid":
            String(localized: "home.voice.provider.keyInvalid", defaultValue: "The dictation service refused the API key. Check it in Settings > Agent Chat.", bundle: .localizedModule)
        case "offline":
            String(localized: "home.voice.provider.offline", defaultValue: "Could not reach the dictation service. Check the connection, or switch Dictation Engine to On This Mac.", bundle: .localizedModule)
        case "timeout":
            String(localized: "home.voice.provider.timeout", defaultValue: "The dictation service took too long to answer. Try again.", bundle: .localizedModule)
        case "rate_limited":
            String(localized: "home.voice.provider.rateLimited", defaultValue: "The dictation service is busy or over its limit. Try again in a moment.", bundle: .localizedModule)
        case "bad_endpoint":
            String(localized: "home.voice.provider.badEndpoint", defaultValue: "The dictation server URL is not usable. Check it in Settings > Agent Chat.", bundle: .localizedModule)
        case "rejected" where detail.isEmpty:
            String(localized: "home.voice.provider.rejected", defaultValue: "The dictation service refused the recording.", bundle: .localizedModule)
        case "rejected":
            String(format: String(localized: "home.voice.provider.rejectedDetail", defaultValue: "The dictation service refused the recording: %@", bundle: .localizedModule), detail)
        case "too_large":
            String(localized: "home.voice.provider.tooLarge", defaultValue: "That recording is too long for the dictation service.", bundle: .localizedModule)
        case "provider_error", "bad_response":
            String(localized: "home.voice.provider.providerError", defaultValue: "The dictation service had a problem. Try again.", bundle: .localizedModule)
        default:
            String(localized: "home.voice.provider.failed", defaultValue: "Dictation failed. Check Dictation Engine in Settings > Agent Chat.", bundle: .localizedModule)
        }
    }
}
