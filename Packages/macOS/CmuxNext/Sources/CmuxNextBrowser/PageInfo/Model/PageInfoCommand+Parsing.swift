import Foundation

/// Why a Page Info action could not run (reported by the App as the
/// action's refusal, e.g. on the CLI).
public nonisolated enum PageInfoCommandError: Error, Hashable, Sendable {
    case invalidArgument(name: String, value: String)
    /// The page has no bubble (blank page, data: URL).
    case noSiteInformation
    /// Permissions, site data and site settings exist for web pages only.
    case notAWebPage
    /// The user did not turn off certificate warnings for this site.
    case certificateWarningsAlreadyOn

    public var message: String {
        switch self {
        case .invalidArgument(let name, let value): PageInfoStrings.invalidArgument(name, value)
        case .noSiteInformation: PageInfoStrings.noSiteInformation
        case .notAWebPage: PageInfoStrings.notAWebPage
        case .certificateWarningsAlreadyOn: PageInfoStrings.certificateWarningsAlreadyOn
        }
    }
}

extension PageInfoCommand {
    /// The command a registry action runs, from its string arguments.
    public static func from(actionID: String, arguments: [String: String]) throws(PageInfoCommandError) -> PageInfoCommand {
        switch actionID {
        case PageInfoCommand.showActionID: return .show(.main)
        case PageInfoCommand.connectionActionID: return .show(.security)
        case PageInfoCommand.cookiesActionID: return .show(.cookies)
        case PageInfoCommand.certificateActionID: return .showCertificate
        case PageInfoCommand.resetPermissionsActionID: return .resetPermissions
        case PageInfoCommand.siteSettingsActionID: return .siteSettings
        case PageInfoCommand.manageSiteDataActionID: return .manageSiteData
        case PageInfoCommand.aboutThisPageActionID: return .aboutThisPage
        case PageInfoCommand.deleteSiteDataActionID:
            let domain = arguments["domain"]?.trimmingCharacters(in: .whitespaces)
            return .deleteSiteData(domain: domain?.isEmpty == false ? domain : nil)
        case PageInfoCommand.setPermissionActionID:
            let permission = arguments["permission"] ?? ""
            let setting = arguments["setting"] ?? ""
            guard let kind = SitePermissionKind(rawValue: permission) else {
                throw .invalidArgument(name: "permission", value: permission)
            }
            guard let value = SitePermissionSetting(rawValue: setting), kind.choices.contains(value) else {
                throw .invalidArgument(name: "setting", value: setting)
            }
            return .setPermission(kind, value)
        default:
            throw .invalidArgument(name: "action", value: actionID)
        }
    }

    /// Every registry action id Page Info handles.
    public static let actionIDs = [
        PageInfoCommand.showActionID, PageInfoCommand.connectionActionID, PageInfoCommand.cookiesActionID, PageInfoCommand.certificateActionID, PageInfoCommand.setPermissionActionID,
        PageInfoCommand.resetPermissionsActionID, PageInfoCommand.siteSettingsActionID, PageInfoCommand.manageSiteDataActionID, PageInfoCommand.deleteSiteDataActionID,
        PageInfoCommand.aboutThisPageActionID,
    ]

    /// Commands that need a web page (not only a bubble).
    var needsWebPage: Bool {
        switch self {
        case .show(.main), .show(.security), .showCertificate, .close, .reload: false
        case .show, .setPermission, .resetPermissions, .siteSettings, .manageSiteData, .deleteSiteData, .aboutThisPage,
             .reenableCertificateWarnings: true
        }
    }
}

extension PageInfoController {
    /// Checks that the current page can run `command`, then runs it.
    public func run(_ command: PageInfoCommand) throws(PageInfoCommandError) {
        guard let tab else { throw .noSiteInformation }
        let site = PageInfoSite(state: tab.state)
        if site.kind == .empty { throw .noSiteInformation }
        if command.needsWebPage, !site.isWeb { throw .notAWebPage }
        perform(command)
    }
}
