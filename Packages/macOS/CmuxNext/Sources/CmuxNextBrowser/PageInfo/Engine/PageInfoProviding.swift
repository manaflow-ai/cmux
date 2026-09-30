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

/// Permission names of the web platform (`navigator.permissions`, DevTools
/// `Browser.setPermission`).
nonisolated enum WebPermissionName {
    static func name(for kind: SitePermissionKind) -> String? {
        switch kind {
        case .location: "geolocation"
        case .camera: "camera"
        case .microphone: "microphone"
        case .notifications: "notifications"
        case .midi: "midi"
        case .clipboard: "clipboard-read"
        case .javascript, .images, .popups, .sound, .automaticDownloads, .usb, .serial, .hid: nil
        }
    }

    /// `granted` / `denied` / `prompt` as a setting.
    static func setting(forState state: String) -> SitePermissionSetting? {
        switch state {
        case "granted": .allow
        case "denied": .block
        case "prompt": .ask
        default: nil
        }
    }

    static func state(for setting: SitePermissionSetting) -> String {
        switch setting {
        case .allow: "granted"
        case .block: "denied"
        case .ask: "prompt"
        }
    }
}
