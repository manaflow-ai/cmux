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

    /// Runs the App's document-commit scripts (``BrowserSharedStores/documentCommitScripts``) in
    /// the isolated world of the document that just committed, in order.
    func runDocumentCommitScripts(_ scripts: [String]) {
        guard !scripts.isEmpty else { return }
        // task-owner: the committed document's installers, in order; a failure (closed, navigated) drops them
        Task { [weak self] in
            for script in scripts { _ = try? await self?.evaluate(script, world: .isolated, gesture: .cmux) }
        }
    }
}
