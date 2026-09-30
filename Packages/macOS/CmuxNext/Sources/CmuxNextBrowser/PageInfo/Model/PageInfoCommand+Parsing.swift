import Foundation

/// Why a Page Info action could not run (reported by the App as the
/// action's refusal, e.g. on the CLI).
public nonisolated enum PageInfoCommandError: Error, Hashable, Sendable {
    case invalidArgument(name: String, value: String)
    /// The page has no bubble (blank page, data: URL).
    case noSiteInformation
    /// Permissions, site data and site settings exist for web pages only.
    case notAWebPage

    public var message: String {
        switch self {
        case .invalidArgument(let name, let value): PageInfoStrings.invalidArgument(name, value)
        case .noSiteInformation: PageInfoStrings.noSiteInformation
        case .notAWebPage: PageInfoStrings.notAWebPage
        }
    }
}

extension PageInfoCommand {
    /// The command a registry action runs, from its string arguments.
    public static func from(actionID: String, arguments: [String: String]) throws(PageInfoCommandError) -> PageInfoCommand {
        switch actionID {
        case ActionID.show: return .show(.main)
        case ActionID.connection: return .show(.security)
        case ActionID.cookies: return .show(.cookies)
        case ActionID.certificate: return .showCertificate
        case ActionID.resetPermissions: return .resetPermissions
        case ActionID.siteSettings: return .siteSettings
        case ActionID.manageSiteData: return .manageSiteData
        case ActionID.aboutThisPage: return .aboutThisPage
        case ActionID.deleteSiteData:
            let domain = arguments["domain"]?.trimmingCharacters(in: .whitespaces)
            return .deleteSiteData(domain: domain?.isEmpty == false ? domain : nil)
        case ActionID.setPermission:
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
        ActionID.show, ActionID.connection, ActionID.cookies, ActionID.certificate, ActionID.setPermission,
        ActionID.resetPermissions, ActionID.siteSettings, ActionID.manageSiteData, ActionID.deleteSiteData,
        ActionID.aboutThisPage,
    ]

    /// Commands that need a web page (not only a bubble).
    var needsWebPage: Bool {
        switch self {
        case .show(.main), .show(.security), .showCertificate, .close, .reload: false
        case .show, .setPermission, .resetPermissions, .siteSettings, .manageSiteData, .deleteSiteData, .aboutThisPage: true
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
