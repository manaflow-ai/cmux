import Foundation

/// A page of the bubble.
public nonisolated enum PageInfoPage: Hashable, Sendable {
    case main
    /// "Connection is secure" details and the certificate row.
    case security
    /// "Cookies and site data".
    case cookies
    /// One permission's choices.
    case permission(SitePermissionKind)
}

/// Everything the bubble can do. Each command is one registry action
/// (palette, CLI, right-click); the bubble sends commands through
/// `PageInfoController.commandRouter` so clicks and the CLI take one path.
public nonisolated enum PageInfoCommand: Hashable, Sendable {
    case show(PageInfoPage)
    case showCertificate
    case setPermission(SitePermissionKind, SitePermissionSetting)
    case resetPermissions
    case siteSettings
    case manageSiteData
    /// Deletes cookies and site data of `domain`, or of the whole site
    /// (every entry the page stored) when nil.
    case deleteSiteData(domain: String?)
    case aboutThisPage
    case reload
    case close

    /// Registry action ids (`ActionCatalog+PageInfo`).
    public enum ActionID {
        public static let show = "browser.pageInfo"
        public static let connection = "browser.pageInfo.connection"
        public static let cookies = "browser.pageInfo.cookies"
        public static let certificate = "browser.pageInfo.certificate"
        public static let setPermission = "browser.pageInfo.setPermission"
        public static let resetPermissions = "browser.pageInfo.resetPermissions"
        public static let siteSettings = "browser.pageInfo.siteSettings"
        public static let manageSiteData = "browser.pageInfo.manageSiteData"
        public static let deleteSiteData = "browser.pageInfo.deleteSiteData"
        public static let aboutThisPage = "browser.pageInfo.aboutThisPage"
    }

    /// The registry action and its string arguments, nil for commands that
    /// only move inside the bubble (permission subpage, close, reload).
    public var action: (id: String, arguments: [String: String])? {
        switch self {
        case .show(.main): (ActionID.show, [:])
        case .show(.security): (ActionID.connection, [:])
        case .show(.cookies): (ActionID.cookies, [:])
        case .show(.permission), .reload, .close: nil
        case .showCertificate: (ActionID.certificate, [:])
        case .setPermission(let kind, let setting): (ActionID.setPermission, ["permission": kind.rawValue, "setting": setting.rawValue])
        case .resetPermissions: (ActionID.resetPermissions, [:])
        case .siteSettings: (ActionID.siteSettings, [:])
        case .manageSiteData: (ActionID.manageSiteData, [:])
        case .deleteSiteData(let domain): (ActionID.deleteSiteData, domain.map { ["domain": $0] } ?? [:])
        case .aboutThisPage: (ActionID.aboutThisPage, [:])
        }
    }
}
