public import Foundation

/// What an engine tells Page Info about its tab, and how Page Info's changes
/// reach the engine. `WebKitTab` and `CEFTab` conform; `MockBrowserTab`
/// conforms with fakes so the bubble can be demoed and tested alone.
public protocol PageInfoProviding: AnyObject {
    var pageInfoActivity: PageInfoActivity { get }
    /// Stores shared by both engines (`SiteSettingsRegistry.shared` unless
    /// the engine was given another).
    var pageInfoSettings: SiteSettingsRegistry { get }
    /// Permissions this engine can enforce; Page Info lists only these.
    var supportedSitePermissions: Set<SitePermissionKind> { get }
    /// The main frame's certificate chain as DER, leaf first; empty for none.
    func pageInfoCertificateChain() async -> [Data]
    /// Cookies and other site data grouped by site.
    func pageInfoSiteData(pageHost: String?) async -> SiteDataSummary
    /// Deletes cookies and site data of each registrable domain.
    func pageInfoDeleteSiteData(domains: [String]) async
    /// The engine's own current values (Chromium keeps its own content
    /// settings and answers `navigator.permissions`); empty when the engine
    /// has none beyond the shared store.
    func pageInfoLivePermissions(origin: String) async -> [SitePermissionKind: SitePermissionSetting]
    /// Page Info changed a decision: apply what the engine can apply now.
    func pageInfoDidChange(_ kind: SitePermissionKind, to setting: SitePermissionSetting, origin: String) async
    /// Permissions the page is using right now (camera, microphone).
    var pageInfoInUse: Set<SitePermissionKind> { get }
}

extension PageInfoProviding where Self: BrowserTab {
    /// The profile's decision store.
    public var sitePermissions: SitePermissionStore { pageInfoSettings.permissions(for: profileID) }
}
