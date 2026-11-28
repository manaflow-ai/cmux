package import CmuxNextCloud
package import Foundation

extension CloudAgentCredentials.Failure {
    /// Localizes a model-connection refusal using the hosting app's catalog.
    package func modelConnectionNotice(harness: String?, bundle: Bundle) -> String {
        guard case .refused(let reason) = self else {
            return String(localized: "cloud.modelConnection.unavailable", defaultValue: "The connection is temporarily unavailable.", bundle: bundle)
        }
        switch reason {
        case "connections.disabled", "connections.not_cloud":
            return String(localized: "cloud.modelConnection.disabled", defaultValue: "This connection is turned off for Cloud chats.", bundle: bundle)
        case "connections.model_unavailable":
            return String(localized: "cloud.modelConnection.modelUnavailable", defaultValue: "This connection cannot use this model. Choose another model or connection.", bundle: bundle)
        case "chatgpt.network", "subscription.network":
            return String(localized: "cloud.modelConnection.offline", defaultValue: "This connection is offline.", bundle: bundle)
        case "chatgpt.keychain_locked", "subscription.keychain_locked":
            let provider = ["codex": "ChatGPT", "grok": "SuperGrok", "github-copilot": "GitHub Copilot", "opencode": "Kimi Code"][harness ?? "codex"] ?? "ChatGPT"
            return String(format: String(localized: "cloud.modelConnection.keychainLocked", defaultValue: "Unlock your Mac's keychain to use %@.", bundle: bundle), provider)
        default:
            if requiresSignIn || reason == "connections.expired" {
                // retry-prompt-ok: a reconnect is a sign-in only the person can do.
                return String(localized: "cloud.modelConnection.expired", defaultValue: "This connection has expired. Reconnect it in Settings > Models.", bundle: bundle)
            }
            return String(localized: "cloud.modelConnection.unavailable", defaultValue: "The connection is temporarily unavailable.", bundle: bundle)
        }
    }
}
