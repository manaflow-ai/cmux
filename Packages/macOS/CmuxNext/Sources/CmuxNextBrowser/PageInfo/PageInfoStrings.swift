import Foundation

/// Page Info strings (table `PageInfo`). English follows Chromium's
/// `components/page_info_strings.grdp` with the product name replaced by cmux.
nonisolated enum PageInfoStrings {
    // Omnibar chip
    static var viewSiteInformation: String { String(localized: "pageInfo.chip.tooltip", defaultValue: "View site information", table: "PageInfo", bundle: .localizedModule) }
    static var notSecure: String { String(localized: "pageInfo.chip.notSecure", defaultValue: "Not secure", table: "PageInfo", bundle: .localizedModule) }
    static var dangerous: String { String(localized: "pageInfo.chip.dangerous", defaultValue: "Dangerous", table: "PageInfo", bundle: .localizedModule) }
    static var file: String { String(localized: "pageInfo.chip.file", defaultValue: "File", table: "PageInfo", bundle: .localizedModule) }
    static var product: String { String(localized: "pageInfo.chip.product", defaultValue: "cmux", table: "PageInfo", bundle: .localizedModule) }

    // Connection
    static var secureSummary: String { String(localized: "pageInfo.security.secure", defaultValue: "Connection is secure", table: "PageInfo", bundle: .localizedModule) }
    static var notSecureSummary: String { String(localized: "pageInfo.security.notSecure", defaultValue: "Connection is not secure", table: "PageInfo", bundle: .localizedModule) }
    static var notSecureSummaryLong: String { String(localized: "pageInfo.security.notSecureLong", defaultValue: "Your connection to this site is not secure", table: "PageInfo", bundle: .localizedModule) }
    static var mixedSummary: String { String(localized: "pageInfo.security.mixed", defaultValue: "Connection is not fully secure", table: "PageInfo", bundle: .localizedModule) }
    static var mixedSummaryLong: String { String(localized: "pageInfo.security.mixedLong", defaultValue: "Your connection to this site is not fully secure", table: "PageInfo", bundle: .localizedModule) }
    static var dangerousSummary: String { String(localized: "pageInfo.security.dangerous", defaultValue: "Dangerous site", table: "PageInfo", bundle: .localizedModule) }
    static var secureDetails: String { String(localized: "pageInfo.security.secureDetails", defaultValue: "Your information (for example, passwords or credit card numbers) is private when it is sent to this site.", table: "PageInfo", bundle: .localizedModule) }
    static var notSecureDetails: String { String(localized: "pageInfo.security.notSecureDetails", defaultValue: "You should not enter any sensitive information on this site (for example, passwords or credit cards), because it could be stolen by attackers.", table: "PageInfo", bundle: .localizedModule) }
    static var mixedDetails: String { String(localized: "pageInfo.security.mixedDetails", defaultValue: "Attackers might be able to see the images you're looking at on this site and trick you by modifying them.", table: "PageInfo", bundle: .localizedModule) }
    static var dangerousDetails: String { String(localized: "pageInfo.security.dangerousDetails", defaultValue: "Attackers on this site might trick you into installing harmful software or revealing things like your passwords, phone, or credit card numbers.", table: "PageInfo", bundle: .localizedModule) }
    static var identityNotVerified: String { String(localized: "pageInfo.security.identityNotVerified", defaultValue: "The identity of this website isn't verified.", table: "PageInfo", bundle: .localizedModule) }
    static var learnMore: String { String(localized: "pageInfo.learnMore", defaultValue: "Learn more", table: "PageInfo", bundle: .localizedModule) }
    static var securityHeader: String { String(localized: "pageInfo.security.header", defaultValue: "Security", table: "PageInfo", bundle: .localizedModule) }
    static var certificateValid: String { String(localized: "pageInfo.certificate.valid", defaultValue: "Certificate is valid", table: "PageInfo", bundle: .localizedModule) }
    static var certificateInvalid: String { String(localized: "pageInfo.certificate.invalid", defaultValue: "Certificate is not valid", table: "PageInfo", bundle: .localizedModule) }
    static func showCertificateIssuedBy(_ issuer: String) -> String {
        String(localized: "pageInfo.certificate.showIssuedBy", defaultValue: "Show certificate (issued by \(issuer))", table: "PageInfo", bundle: .localizedModule)
    }
    static var certificateWarningsTurnedOff: String { String(localized: "pageInfo.security.warningsTurnedOff", defaultValue: "You have chosen to turn off security warnings for this site.", table: "PageInfo", bundle: .localizedModule) }
    /// Under "Turn on warnings" on Chromium, which clears every site's choice.
    static var certificateWarningsAllSites: String { String(localized: "pageInfo.security.turnOnWarnings.allSites", defaultValue: "For all sites in this profile", table: "PageInfo", bundle: .localizedModule) }
    /// The notice after "Turn on warnings".
    static func certificateWarningsOnAgain(_ scope: BrowserCertificateWarningScope) -> String {
        switch scope {
        case .site: String(localized: "pageInfo.security.warningsOnAgain.site", defaultValue: "Security warnings are on again for this site.", table: "PageInfo", bundle: .localizedModule)
        case .profile: String(localized: "pageInfo.security.warningsOnAgain.profile", defaultValue: "Security warnings are on again for all sites in this profile.", table: "PageInfo", bundle: .localizedModule)
        }
    }
    static var turnOnCertificateWarnings: String { String(localized: "pageInfo.security.turnOnWarnings", defaultValue: "Turn on warnings", table: "PageInfo", bundle: .localizedModule) }
    static var showCertificate: String { String(localized: "pageInfo.certificate.show", defaultValue: "Show certificate", table: "PageInfo", bundle: .localizedModule) }

    // Identity lines for non-web pages
    static var filePage: String { String(localized: "pageInfo.identity.file", defaultValue: "You're viewing a local or shared file", table: "PageInfo", bundle: .localizedModule) }
    static var internalPage: String { String(localized: "pageInfo.identity.internal", defaultValue: "You're viewing a secure cmux page", table: "PageInfo", bundle: .localizedModule) }
    static var extensionPage: String { String(localized: "pageInfo.identity.extension", defaultValue: "You're viewing an extension page", table: "PageInfo", bundle: .localizedModule) }
    static var viewSourcePage: String { String(localized: "pageInfo.identity.viewSource", defaultValue: "You're viewing the source of a web page", table: "PageInfo", bundle: .localizedModule) }
    static var devToolsPage: String { String(localized: "pageInfo.identity.devTools", defaultValue: "You're viewing a developer tools page", table: "PageInfo", bundle: .localizedModule) }

    // Permission states
    static var allowed: String { String(localized: "pageInfo.state.allowed", defaultValue: "Allowed", table: "PageInfo", bundle: .localizedModule) }
    static var notAllowed: String { String(localized: "pageInfo.state.notAllowed", defaultValue: "Not allowed", table: "PageInfo", bundle: .localizedModule) }
    static var allowedByDefault: String { String(localized: "pageInfo.state.allowedDefault", defaultValue: "Allowed (default)", table: "PageInfo", bundle: .localizedModule) }
    static var notAllowedByDefault: String { String(localized: "pageInfo.state.notAllowedDefault", defaultValue: "Not allowed (default)", table: "PageInfo", bundle: .localizedModule) }
    static var muted: String { String(localized: "pageInfo.state.muted", defaultValue: "Muted", table: "PageInfo", bundle: .localizedModule) }
    static var automaticByDefault: String { String(localized: "pageInfo.state.automaticDefault", defaultValue: "Automatic (default)", table: "PageInfo", bundle: .localizedModule) }
    static var usingNow: String { String(localized: "pageInfo.state.usingNow", defaultValue: "Using now", table: "PageInfo", bundle: .localizedModule) }

    // Choices (permission subpage and Site settings)
    static var askDefault: String { String(localized: "pageInfo.choice.askDefault", defaultValue: "Ask (default)", table: "PageInfo", bundle: .localizedModule) }
    static var ask: String { String(localized: "pageInfo.choice.ask", defaultValue: "Ask", table: "PageInfo", bundle: .localizedModule) }
    static var allow: String { String(localized: "pageInfo.choice.allow", defaultValue: "Allow", table: "PageInfo", bundle: .localizedModule) }
    static var block: String { String(localized: "pageInfo.choice.block", defaultValue: "Block", table: "PageInfo", bundle: .localizedModule) }
    static var allowDefault: String { String(localized: "pageInfo.choice.allowDefault", defaultValue: "Allow (default)", table: "PageInfo", bundle: .localizedModule) }
    static var blockDefault: String { String(localized: "pageInfo.choice.blockDefault", defaultValue: "Block (default)", table: "PageInfo", bundle: .localizedModule) }
    static var mute: String { String(localized: "pageInfo.choice.mute", defaultValue: "Mute", table: "PageInfo", bundle: .localizedModule) }
    static var resetPermission: String { String(localized: "pageInfo.reset.one", defaultValue: "Reset permission", table: "PageInfo", bundle: .localizedModule) }
    static var resetPermissions: String { String(localized: "pageInfo.reset.many", defaultValue: "Reset permissions", table: "PageInfo", bundle: .localizedModule) }
    static var reloadToApply: String { String(localized: "pageInfo.reload.text", defaultValue: "Reload this page to apply your updated settings on this site", table: "PageInfo", bundle: .localizedModule) }
    static var reload: String { String(localized: "pageInfo.reload.button", defaultValue: "Reload", table: "PageInfo", bundle: .localizedModule) }
    static var manage: String { String(localized: "pageInfo.permission.manage", defaultValue: "Manage", table: "PageInfo", bundle: .localizedModule) }

    // Cookies
    static var cookiesHeader: String { String(localized: "pageInfo.cookies.header", defaultValue: "Cookies and site data", table: "PageInfo", bundle: .localizedModule) }
    static var thirdPartyCookies: String { String(localized: "pageInfo.cookies.thirdParty", defaultValue: "Third-party cookies", table: "PageInfo", bundle: .localizedModule) }
    static var thirdPartyBlocked: String { String(localized: "pageInfo.cookies.thirdPartyBlocked", defaultValue: "Blocked by this browser engine", table: "PageInfo", bundle: .localizedModule) }
    static var manageSiteData: String { String(localized: "pageInfo.cookies.manage", defaultValue: "Manage on-device site data", table: "PageInfo", bundle: .localizedModule) }
    static func cookieCount(_ count: Int) -> String {
        String(localized: "pageInfo.cookies.count", defaultValue: "Cookies from this site: \(count)", table: "PageInfo", bundle: .localizedModule)
    }
    static func siteCount(_ count: Int) -> String {
        String(localized: "pageInfo.cookies.sites", defaultValue: "Sites with data: \(count)", table: "PageInfo", bundle: .localizedModule)
    }
    static var deleteSiteData: String { String(localized: "pageInfo.cookies.delete", defaultValue: "Delete site data", table: "PageInfo", bundle: .localizedModule) }
    /// The cookies page and the tab notice after "Delete site data" failed; `reason` is the engine's.
    static func deleteSiteDataFailed(_ reason: String) -> String {
        String(localized: "pageInfo.cookies.deleteFailed", defaultValue: "Couldn't delete site data: \(reason)", table: "PageInfo", bundle: .localizedModule)
    }
    static var loading: String { String(localized: "pageInfo.loading", defaultValue: "Loading…", table: "PageInfo", bundle: .localizedModule) }

    // Rows
    static var siteSettings: String { String(localized: "pageInfo.siteSettings", defaultValue: "Site settings", table: "PageInfo", bundle: .localizedModule) }
    static var aboutThisPage: String { String(localized: "pageInfo.about.title", defaultValue: "About this page", table: "PageInfo", bundle: .localizedModule) }
    static var aboutThisPageDescription: String { String(localized: "pageInfo.about.description", defaultValue: "Learn about its source and topic", table: "PageInfo", bundle: .localizedModule) }
    static var close: String { String(localized: "pageInfo.close", defaultValue: "Close", table: "PageInfo", bundle: .localizedModule) }
    static var back: String { String(localized: "pageInfo.back", defaultValue: "Back", table: "PageInfo", bundle: .localizedModule) }

    // Prompt bar (permission prompt buttons)
    static var promptAllowWhileVisiting: String { String(localized: "pageInfo.prompt.allowWhileVisiting", defaultValue: "Allow while visiting the site", table: "PageInfo", bundle: .localizedModule) }
    static var promptAllowThisTime: String { String(localized: "pageInfo.prompt.allowThisTime", defaultValue: "Allow this time", table: "PageInfo", bundle: .localizedModule) }
    static var promptNeverAllow: String { String(localized: "pageInfo.prompt.neverAllow", defaultValue: "Never allow", table: "PageInfo", bundle: .localizedModule) }
}
