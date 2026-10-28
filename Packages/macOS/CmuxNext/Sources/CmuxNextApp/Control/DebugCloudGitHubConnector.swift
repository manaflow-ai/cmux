import AppKit
import CmuxNextCloud
import CmuxNextCloudUI
import CmuxNextDesign

#if DEBUG || CMUX_BENCH_HOOKS
/// Native gallery fixtures. No account, browser, credential or machine is accessed.
@MainActor
struct DebugCloudGitHubConnector {
    func show(_ name: String, center: CmuxDialogCenter, scope: CmuxDialogScope) -> Int? {
        let prefix = "cloudGitHub"
        guard name.hasPrefix(prefix) else { return nil }
        let suffix = String(name.dropFirst(prefix.count)).lowercased()
        let variant = CloudGitHubConnectorCard.Variant(rawValue: suffix) ?? .balanced
        let state: CloudConnectorState = switch suffix {
        case "available": .available
        case "expired": .expired
        case "needsauth": .needsAuth
        default: .installed
        }
        let model = CloudGitHubConnectorModel(client: Fixture(state: state), openInstallURL: { _ in }, retryRepository: {})
        let card = CloudGitHubConnectorCard(model: model, variant: variant)
        let spec = suffix == "auto" ? CloudGitHubConnectorCard.recoveryDialog(reason: CloudGitHubConnectorCard.failureMessage(.privateRepository))
            : CloudWorkspaceSetupWizard.setupDialogSpec(source: .repository, repository: "octo/paint")
        let id = center.present(spec, in: scope, accessory: card.accessory) { _ in }
        card.onSelectRepository = { repo in center.setValue(.text(repo.spec), for: "repository", in: id) }
        return id
    }

    private struct Fixture: CloudGitHubConnectorClient {
        let state: CloudConnectorState
        func connectorStatuses() async throws -> [CloudConnectorStatus] { [.init(provider: "github", state: state)] }
        func installURL() async throws -> URL { throw CloudGitHubConnectorClientError.unavailable }
        func repositories(query: String, cursor: String?) async throws -> CloudGitHubRepositoryPage {
            let repos = [CloudGitHubRepository(owner: "octo", name: "paint", isPrivate: true, defaultBranch: "main"),
                         CloudGitHubRepository(owner: "octo-team", name: "website", isPrivate: false, defaultBranch: "main")]
            return .init(repos: repos.filter { query.isEmpty || $0.id.localizedCaseInsensitiveContains(query) })
        }
    }
}
#endif
