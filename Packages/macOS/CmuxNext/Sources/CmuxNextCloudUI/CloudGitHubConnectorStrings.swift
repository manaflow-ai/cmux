import CmuxNextCloud
import Foundation

/// Localized copy for the connector card, including recoverable repo failures.
struct CloudGitHubConnectorStrings {
    static let recoveryTitle = String(localized: "cloud.connector.recoveryTitle", defaultValue: "Finish repository setup", table: "Cloud", bundle: .module)
    static let dismiss = String(localized: "cloud.connector.dismiss", defaultValue: "Dismiss", table: "Cloud", bundle: .module)
    static let retry = String(localized: "cloud.connector.retry", defaultValue: "Retry repository", table: "Cloud", bundle: .module)
    static let title = String(localized: "cloud.connector.title", defaultValue: "Connect GitHub", table: "Cloud", bundle: .module)
    static let connect = String(localized: "cloud.connector.connect", defaultValue: "Connect", table: "Cloud", bundle: .module)
    static let manage = String(localized: "cloud.connector.manage", defaultValue: "Manage access", table: "Cloud", bundle: .module)
    static let refresh = String(localized: "cloud.connector.refresh", defaultValue: "Refresh", table: "Cloud", bundle: .module)
    static let more = String(localized: "cloud.connector.more", defaultValue: "More", table: "Cloud", bundle: .module)
    static let search = String(localized: "cloud.connector.search", defaultValue: "Find a repository", table: "Cloud", bundle: .module)
    static let repositories = String(localized: "cloud.connector.repositories", defaultValue: "Choose a GitHub repository…", table: "Cloud", bundle: .module)
    static let privateLabel = String(localized: "cloud.connector.private", defaultValue: "Private", table: "Cloud", bundle: .module)
    static let detail = String(localized: "cloud.connector.detail", defaultValue: "Use repositories from your connected accounts and organizations. You can also type owner/repo or use gh auth login on the machine.", table: "Cloud", bundle: .module)

    static func state(_ state: CloudConnectorState?) -> String {
        switch state {
        case .available: String(localized: "cloud.connector.available", defaultValue: "Available", table: "Cloud", bundle: .module)
        case .installed: String(localized: "cloud.connector.installed", defaultValue: "Connected", table: "Cloud", bundle: .module)
        case .needsAuth: String(localized: "cloud.connector.needsAuth", defaultValue: "Sign-in needed", table: "Cloud", bundle: .module)
        case .expired: String(localized: "cloud.connector.expired", defaultValue: "Access expired", table: "Cloud", bundle: .module)
        case nil: String(localized: "cloud.connector.unknown", defaultValue: "Not checked", table: "Cloud", bundle: .module)
        }
    }

    static func error(_ error: CloudGitHubConnectorClientError) -> String {
        switch error {
        case .privateRepository: String(localized: "cloud.connector.privateFailure", defaultValue: "This private repository needs access. Connect GitHub and include it in the installation.", table: "Cloud", bundle: .module)
        case .notFound: String(localized: "cloud.connector.notFound", defaultValue: "Repository not found or not visible to this installation. Check owner/repo and repository access.", table: "Cloud", bundle: .module)
        case .offline: String(localized: "cloud.connector.offline", defaultValue: "GitHub could not be reached. Check your connection, then retry the repository step.", table: "Cloud", bundle: .module)
        case .unauthorized: String(localized: "cloud.connector.unauthorized", defaultValue: "Sign in again to reconnect GitHub.", table: "Cloud", bundle: .module)
        case .unavailable: String(localized: "cloud.connector.unavailable", defaultValue: "GitHub connector setup is not available with this Cloud connection yet. You can still type a repository or use the machine’s GitHub login.", table: "Cloud", bundle: .module)
        case .requestFailed: String(localized: "cloud.connector.failed", defaultValue: "Could not check GitHub access. Refresh to try again.", table: "Cloud", bundle: .module)
        }
    }
}
