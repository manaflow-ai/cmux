import CmuxNextApps
import Foundation

/// Demo app states through the real reducer: the five first-party apps
/// default-installed (samples not), PR Radar and Snippets user-installed,
/// one team-installed app; Usage and Snippets hidden, Notes disabled.
@MainActor
public final class AppInstallsMockSource: AppInstallStateSource {
    public let listings: [AppPermissionsListing]
    public private(set) var store: AppStateStore
    /// The user is not an admin of the team that installed the team app.
    public var teamAdmin = false
    private var counter = 0

    public static let teamSample = AppPermissionsListing(
        id: "acme/standup", name: "Standup", publisher: "Your team", version: "1.2.0", symbol: "person.3", tier: .verified,
        required: [AppPermissionsMockSource.request("workspace:read", "Show who works where.")])

    public init() {
        listings = AppPermissionsMockSource.firstParty + [AppPermissionsMockSource.verifiedSample, Self.teamSample,
                                                          AppPermissionsMockSource.unverifiedSample]
        let catalog = AppPermissionsMockSource.firstParty.map { AppCatalogEntry(appID: $0.id, tier: .firstParty) }
            + [AppCatalogEntry(appID: "cmux/github-prs", tier: .firstParty, isSample: true)]
        store = AppDefaultInstalls.bootstrap(AppStateStore(), catalog: catalog).0
        seed(.install(.user), AppPermissionsMockSource.verifiedSample.id)
        seed(.install(.user), AppPermissionsMockSource.unverifiedSample.id)
        seed(.install(.team), Self.teamSample.id, actor: AppStateActor(origin: .user, teamAdmin: true))
        seed(.hide, "cmux/usage")
        seed(.setHiddenAccess(cli: nil, mcp: false, automations: nil), "cmux/usage")
        seed(.hide, AppPermissionsMockSource.unverifiedSample.id)
        seed(.setHiddenAccess(cli: false, mcp: false, automations: false), AppPermissionsMockSource.unverifiedSample.id)
        seed(.disable, "cmux/notes")
    }

    public func state(for appID: String) -> AppInstallState? { store.apps[appID] }

    public func send(_ op: AppStateOp) async -> Result<AppStateCommit, AppStateReject> {
        sendNow(op, actor: AppStateActor(origin: .user, teamAdmin: teamAdmin))
    }

    @discardableResult
    func sendNow(_ op: AppStateOp, actor: AppStateActor) -> Result<AppStateCommit, AppStateReject> {
        AppStateReducer.apply(op, to: store, actor: actor).map { next, commit in
            store = next
            return commit
        }
    }

    private func seed(_ kind: AppStateOp.Kind, _ app: String, actor: AppStateActor = .user) {
        counter += 1
        sendNow(AppStateOp(key: "seed-\(counter)", app: app, kind: kind), actor: actor)
    }
}
