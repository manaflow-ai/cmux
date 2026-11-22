public import Foundation
public import Observation

/// What the app management surfaces read and send. The App implements it
/// over the app state owner (`UserDO`, `TeamDO` for team installs).
@MainActor
public protocol AppInstallStateSource: AnyObject {
    var listings: [AppPermissionsListing] { get }
    func state(for appID: String) -> AppInstallState?
    /// Whether this user administers the team that installed `appID`
    /// (team installs only; members never remove them).
    func isTeamAdmin(for appID: String) -> Bool
    /// Sends one op with origin `user`; answers the owner's result.
    func send(_ op: AppStateOp) async -> Result<AppStateCommit, AppStateReject>
    /// Registers the one receiver of owner events: every commit from any
    /// channel or device (a CLI hide, another Mac), in owner order per app.
    func observe(_ handler: @escaping @MainActor ([AppStateEvent]) -> Void)
}

/// Installed Apps, Show Hidden Apps and the hidden-access toggles. A
/// projection: `states` change only from owner events (`app.changed` with a
/// higher revision than the mirror holds).
@MainActor
@Observable
public final class AppInstallsModel {
    public let source: any AppInstallStateSource
    public private(set) var states: [String: AppInstallState] = [:]
    /// A default-installed app whose Remove waits for confirmation.
    public var confirmingRemoval: String?
    public private(set) var lastReject: AppStateReject?
    /// Apps with an op in flight; taps on them are ignored until it settles.
    public private(set) var sending: Set<String> = []
    @ObservationIgnored private let makeKey: @MainActor () -> String
    /// The App presents the Show Hidden Apps sheet (`.hiddenApps`) here.
    @ObservationIgnored public var onShowHidden: @MainActor () -> Void = {}
    /// The sheet's Done.
    @ObservationIgnored public var onDismissHidden: @MainActor () -> Void = {}

    public init(source: any AppInstallStateSource, makeKey: @escaping @MainActor () -> String = { UUID().uuidString }) {
        self.source = source
        self.makeKey = makeKey
        for listing in source.listings {
            if let state = source.state(for: listing.id) { states[listing.id] = state }
        }
        source.observe { [weak self] events in self?.receive(events) }
    }

    /// Applies owner events: a record replaces the mirror only when its
    /// revision is higher, so reordered or repeated events never go back.
    public func receive(_ events: [AppStateEvent]) {
        for case .changed(let record) in events where record.revision > (states[record.appID]?.revision ?? 0) || states[record.appID] == nil {
            states[record.appID] = record
        }
    }

    /// Installed apps, in listing order.
    public var installed: [AppPermissionsListing] { source.listings.filter { states[$0.id]?.installed == true } }
    public var hidden: [AppPermissionsListing] { installed.filter { states[$0.id]?.hidden == true } }

    /// Whether this user may remove the app (team installs: admins only).
    public func canRemove(_ app: String) -> Bool { states[app]?.source != .team || source.isTeamAdmin(for: app) }

    public func send(_ kind: AppStateOp.Kind, app: String) async {
        guard sending.insert(app).inserted else { return }
        defer { sending.remove(app) }
        let result = await source.send(AppStateOp(key: makeKey(), app: app, kind: kind))
        if case .failure(let reject) = result { lastReject = reject } else { lastReject = nil }
        if confirmingRemoval == app { confirmingRemoval = nil }
    }

    /// Remove: a default-installed app first asks; others go at once.
    public func remove(_ app: String) async {
        guard !sending.contains(app), canRemove(app) else { return }
        if states[app]?.source == .default, confirmingRemoval != app {
            confirmingRemoval = app
            return
        }
        await send(.remove(confirmed: true), app: app)
    }

    public func presentHidden() { onShowHidden() }
    public func dismissHidden() { onDismissHidden() }
}
