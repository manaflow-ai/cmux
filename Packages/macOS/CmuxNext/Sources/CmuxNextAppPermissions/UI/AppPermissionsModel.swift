import Foundation
public import Observation

/// What the permission surfaces read and write. The App implements it
/// over the grant owner (`UserDO` / `TeamDO` through the supervisor); every
/// change it receives is user origin (only these surfaces call it).
@MainActor
public protocol AppPermissionsDataSource: AnyObject {
    var listings: [AppPermissionsListing] { get }
    func record(for appID: String) -> AppPermissionRecord?
    /// The last 7 days of op calls, newest first.
    func activity(for appID: String) -> [AppActivityEntry]
    var workspaces: [AppResourceOption] { get }
    var rooms: [AppResourceOption] { get }
    var machines: [AppResourceOption] { get }
    /// Sends one grant change with origin `user`; answers the owner's result.
    func apply(_ change: AppGrantChange, appID: String) async -> Result<AppPermissionRecord, AppGrantRejection>
    /// Writes the install record (the consent sheet's Install).
    func install(_ record: AppPermissionRecord) async
    func removeAppData(appID: String) async
    /// Shows the host file panel; nil when the user cancels.
    func pickFolder(appID: String) async -> AppFileRoot?
}

/// The Settings > Apps > <app> > Permissions state: a projection of the
/// data source, refreshed after every change it sends.
@MainActor
@Observable
public final class AppPermissionsModel {
    public let source: any AppPermissionsDataSource
    public private(set) var listings: [AppPermissionsListing]
    public private(set) var records: [String: AppPermissionRecord] = [:]
    public private(set) var activity: [String: [AppActivityEntry]] = [:]
    public var selectedAppID: String?
    /// Install state for the pane's "While Hidden" section (nil hides it).
    public var installs: AppInstallsModel?
    /// The last refused change, shown under the pane until the next change.
    public private(set) var lastRejection: AppGrantRejection?

    public init(source: any AppPermissionsDataSource, selectedAppID: String? = nil) {
        self.source = source
        listings = source.listings
        self.selectedAppID = selectedAppID ?? source.listings.first?.id
        reload()
    }

    public var selected: AppPermissionsListing? { listings.first { $0.id == selectedAppID } }

    public func reload() {
        listings = source.listings
        for listing in listings {
            records[listing.id] = source.record(for: listing.id)
            activity[listing.id] = source.activity(for: listing.id)
        }
    }

    public func apply(_ change: AppGrantChange, appID: String) async {
        switch await source.apply(change, appID: appID) {
        case .success(let record):
            records[appID] = record
            lastRejection = nil
        case .failure(let rejection):
            lastRejection = rejection
        }
        activity[appID] = source.activity(for: appID)
    }

    public func addFolder(appID: String) async {
        guard let root = await source.pickFolder(appID: appID) else { return }
        await apply(.addFileRoot(root), appID: appID)
    }

    public func removeAppData(appID: String) async {
        await source.removeAppData(appID: appID)
        reload()
    }
}

/// The consent sheet state for one install.
@MainActor
@Observable
public final class AppConsentModel {
    public let listing: AppPermissionsListing
    public var draft: AppInstallDraft
    @ObservationIgnored public var onFinish: @MainActor (AppPermissionRecord?) -> Void

    public init(listing: AppPermissionsListing, profile: AppSandboxProfile? = nil,
                onFinish: @escaping @MainActor (AppPermissionRecord?) -> Void = { _ in }) {
        self.listing = listing
        draft = listing.installDraft(profile: profile)
        self.onFinish = onFinish
    }

    public func install() { onFinish(draft.record()) }
    public func cancel() { onFinish(nil) }
}
