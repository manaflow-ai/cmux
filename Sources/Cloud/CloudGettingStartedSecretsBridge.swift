import Foundation
import Observation

/// The seam between the "Get started" card and Cloud Secrets.
///
/// The card's first step needs two things it does not own: how many secrets
/// the vault holds, and a way to open the Cloud Secrets sheet. The secrets
/// service and its sheet publish those here at app start, so the card never
/// imports either one and builds without them.
///
/// Until `secretCount` is set the keys step is left out of the card. With a
/// count but no `openSecrets`, the step teaches the CLI import instead.
@MainActor
@Observable
final class CloudGettingStartedSecretsBridge {
    static let shared = CloudGettingStartedSecretsBridge()

    /// Names in the vault across every scope. Never values.
    var secretCount: Int?
    /// Opens the Cloud Secrets sheet, preferably on its empty state.
    var openSecrets: (() -> Void)?

    init(secretCount: Int? = nil, openSecrets: (() -> Void)? = nil) {
        self.secretCount = secretCount
        self.openSecrets = openSecrets
    }
}
