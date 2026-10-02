public import Foundation
public import Observation

/// What the app management surfaces read and send. The App implements it
/// over the app state owner (`UserDO`, `TeamDO` for team installs).
@MainActor
public protocol AppInstallStateSource: AnyObject {
    var listings: [AppPermissionsListing] { get }
    func state(for appID: String) -> AppInstallState?
    /// Sends one op with origin `user`; answers the owner's result.
    func send(_ op: AppStateOp) async -> Result<AppStateCommit, AppStateReject>
}

/// Installed Apps, Show Hidden Apps and the hidden-access toggles.
@MainActor
@Observable
public final class AppInstallsModel {
    public let source: any AppInstallStateSource
    public private(set) var states: [String: AppInstallState] = [:]
    /// A default-installed app whose Remove waits for confirmation.
    public var confirmingRemoval: String?
    public private(set) var lastReject: AppStateReject?
    @ObservationIgnored private let makeKey: @MainActor () -> String
    /// The App presents the Show Hidden Apps sheet (`.hiddenApps`) here.
    @ObservationIgnored public var onShowHidden: @MainActor () -> Void = {}
    /// The sheet's Done.
    @ObservationIgnored public var onDismissHidden: @MainActor () -> Void = {}

    public init(source: any AppInstallStateSource, makeKey: @escaping @MainActor () -> String = { UUID().uuidString }) {
        self.source = source
        self.makeKey = makeKey
        reload()
    }

    public func reload() {
        for listing in source.listings { states[listing.id] = source.state(for: listing.id) }
    }

    /// Installed apps, in listing order.
    public var installed: [AppPermissionsListing] { source.listings.filter { states[$0.id]?.installed == true } }
    public var hidden: [AppPermissionsListing] { installed.filter { states[$0.id]?.hidden == true } }

    public func send(_ kind: AppStateOp.Kind, app: String) async {
        let result = await source.send(AppStateOp(key: makeKey(), app: app, kind: kind))
        if case .failure(let reject) = result { lastReject = reject } else { lastReject = nil }
        confirmingRemoval = nil
        states[app] = source.state(for: app)
    }

    public func presentHidden() { onShowHidden() }
    public func dismissHidden() { onDismissHidden() }

    /// Remove: a default-installed app first asks; others go at once.
    public func remove(_ app: String) async {
        if states[app]?.source == .default, confirmingRemoval != app {
            confirmingRemoval = app
            return
        }
        await send(.remove(confirmed: true), app: app)
    }
}
