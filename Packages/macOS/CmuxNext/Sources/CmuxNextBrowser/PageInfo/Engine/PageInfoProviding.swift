public import Foundation

/// What an engine tells Page Info about its tab, and how Page Info's changes
/// reach the engine. `WebKitTab` and `CEFTab` conform; `MockBrowserTab`
/// conforms with fakes so the bubble can be demoed and tested alone.
public protocol PageInfoProviding: AnyObject {
    var pageInfoActivity: PageInfoActivity { get }
    /// Stores shared by both engines (the App's ``BrowserSharedStores``).
    var pageInfoSettings: SiteSettingsRegistry { get }
    /// Permissions this engine can enforce; Page Info lists only these.
    var supportedSitePermissions: Set<SitePermissionKind> { get }
    /// The main frame's certificate chain as DER, leaf first; empty for none.
    func pageInfoCertificateChain() async -> [Data]
    /// Cookies and other site data grouped by site.
    func pageInfoSiteData(pageHost: String?) async -> SiteDataSummary
    /// Deletes cookies and site data of each registrable domain; throws what
    /// it could not delete, after deleting all it could.
    func pageInfoDeleteSiteData(domains: [String]) async throws(PageInfoSiteDataDeleteError)
    /// The engine's own current values (Chromium keeps its own content
    /// settings and answers `navigator.permissions`); empty when the engine
    /// has none beyond the shared store.
    func pageInfoLivePermissions(origin: String) async -> [SitePermissionKind: SitePermissionSetting]
    /// Page Info changed a decision: apply what the engine can apply now.
    func pageInfoDidChange(_ kind: SitePermissionKind, to setting: SitePermissionSetting, origin: String) async
    /// Permissions the page is using right now (camera, microphone).
    var pageInfoInUse: Set<SitePermissionKind> { get }
}

/// Why "Delete site data" did not delete everything. Page Info says so with
/// the reason (`PageInfoStrings.deleteSiteDataFailed`) instead of showing the
/// counts as if the data were gone.
public enum PageInfoSiteDataDeleteError: Error, Equatable, Sendable {
    /// The tab has no engine browser any more (closed or not yet created).
    case tabClosed
    /// The cookie jar could not be read, so no cookie was deleted.
    case cookiesUnreadable(reason: String)
    /// `count` cookies stayed; `reason` is the last failure's.
    case cookiesNotDeleted(count: Int, reason: String)
    /// `count` origins kept their storage; `reason` is the last failure's.
    case storageNotCleared(count: Int, reason: String)

    /// The engine's own words for the failure.
    public var reason: String {
        switch self {
        case .tabClosed: "the tab is closed"
        case let .cookiesUnreadable(reason): "cookies could not be read (\(reason))"
        case let .cookiesNotDeleted(count, reason): "\(count) cookies were not deleted (\(reason))"
        case let .storageNotCleared(count, reason): "storage of \(count) origins was not cleared (\(reason))"
        }
    }

    /// An engine error's description for `reason`.
    static func describe(_ error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

extension PageInfoProviding where Self: BrowserTab {
    /// The profile's decision store.
    public var sitePermissions: SitePermissionStore { pageInfoSettings.permissions(for: profileID) }
}
