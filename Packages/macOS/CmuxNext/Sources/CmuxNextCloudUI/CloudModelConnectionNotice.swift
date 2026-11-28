package import CmuxNextCloud
package import Foundation

/// A model-connection refusal's words, in the hosting app's catalog; the App's chat notice draws them with its
/// Settings action (`AgentTabStore.showCredentialNotice`).
package struct CloudModelConnectionText {
    package init() {}

    /// Localizes `failure` using `bundle` (the hosting app's catalog).
    package static func notice(_ failure: CloudAgentCredentials.Failure, harness: String?, bundle: Bundle) -> String {
        let reason = refusal(of: failure) ?? ""
        switch reason {
        case "connections.disabled", "connections.not_cloud":
            return String(localized: "cloud.modelConnection.disabled", defaultValue: "This connection is turned off for Cloud chats.", bundle: bundle)
        case "connections.model_unavailable":
            return String(localized: "cloud.modelConnection.modelUnavailable", defaultValue: "This connection cannot use this model. Choose another model or connection.", bundle: bundle)
        case "chatgpt.network", "subscription.network":
            return String(localized: "cloud.modelConnection.offline", defaultValue: "This connection is offline. Connect to the internet to use it.", bundle: bundle)
        case "chatgpt.keychain_locked", "subscription.keychain_locked":
            let provider = ["codex": "ChatGPT", "grok": "SuperGrok", "github-copilot": "GitHub Copilot", "opencode": "Kimi Code"][harness ?? "codex"] ?? "ChatGPT"
            return String(format: String(localized: "cloud.modelConnection.keychainLocked", defaultValue: "Unlock your Mac's keychain to use %@.", bundle: bundle), provider)
        default:
            if failure.requiresSignIn || reason == "connections.expired" {
                // retry-prompt-ok: reconnecting is a sign-in only the person can do
                return String(localized: "cloud.modelConnection.expired", defaultValue: "This connection has expired. Reconnect it in Settings > Models.", bundle: bundle)
            }
            return String(localized: "cloud.modelConnection.unavailable", defaultValue: "The connection is temporarily unavailable.", bundle: bundle)
        }
    }

    /// The refusal's reason; nil when acpmux gave no credential at all (``CloudAgentCredentials/Failure/unavailable(connection:)``).
    private static func refusal(of failure: CloudAgentCredentials.Failure) -> String? {
        guard case .refused(let reason) = failure else { return nil }
        return reason
    }
}
