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
    /// Turns certificate warnings on again for a site the user proceeded
    /// past, and reloads (Chrome's "Turn on warnings").
    case reenableCertificateWarnings
    case reload
    case close

    /// Registry action ids (`ActionCatalog+PageInfo`).
    public static let showActionID = "browser.pageInfo"
    public static let connectionActionID = "browser.pageInfo.connection"
    public static let cookiesActionID = "browser.pageInfo.cookies"
    public static let certificateActionID = "browser.pageInfo.certificate"
    public static let setPermissionActionID = "browser.pageInfo.setPermission"
    public static let resetPermissionsActionID = "browser.pageInfo.resetPermissions"
    public static let siteSettingsActionID = "browser.pageInfo.siteSettings"
    public static let manageSiteDataActionID = "browser.pageInfo.manageSiteData"
    public static let deleteSiteDataActionID = "browser.pageInfo.deleteSiteData"
    public static let aboutThisPageActionID = "browser.pageInfo.aboutThisPage"
    public static let reenableCertificateWarningsActionID = "browser.pageInfo.reenableCertificateWarnings"

    /// The registry action and its string arguments, nil for commands that
    /// only move inside the bubble (permission subpage, close, reload).
    public var action: (id: String, arguments: [String: String])? {
        switch self {
        case .show(.main): (PageInfoCommand.showActionID, [:])
        case .show(.security): (PageInfoCommand.connectionActionID, [:])
        case .show(.cookies): (PageInfoCommand.cookiesActionID, [:])
        case .show(.permission), .reload, .close, .reenableCertificateWarnings: nil
        case .showCertificate: (PageInfoCommand.certificateActionID, [:])
        case .setPermission(let kind, let setting): (PageInfoCommand.setPermissionActionID, ["permission": kind.rawValue, "setting": setting.rawValue])
        case .resetPermissions: (PageInfoCommand.resetPermissionsActionID, [:])
        case .siteSettings: (PageInfoCommand.siteSettingsActionID, [:])
        case .manageSiteData: (PageInfoCommand.manageSiteDataActionID, [:])
        case .deleteSiteData(let domain): (PageInfoCommand.deleteSiteDataActionID, domain.map { ["domain": $0] } ?? [:])
        case .aboutThisPage: (PageInfoCommand.aboutThisPageActionID, [:])
        }
    }
}
