import Foundation

nonisolated extension PageInfoStrings {
    // The Page Info windows' native titles; their content is React (webviews/src/pages/site-data,
    // site-settings, certificate) with its strings in the page-info catalog.
    static var siteDataTitle: String { String(localized: "pageInfo.siteData.title", defaultValue: "On-device site data", table: "PageInfo", bundle: .module) }

    static func siteSettingsTitle(_ site: String) -> String {
        String(localized: "pageInfo.siteSettings.windowTitle", defaultValue: "Site settings: \(site)", table: "PageInfo", bundle: .module)
    }

    static func viewerTitle(_ name: String) -> String {
        String(localized: "pageInfo.viewer.title", defaultValue: "Certificate Viewer: \(name)", table: "PageInfo", bundle: .module)
    }

    // Action refusals
    static func invalidArgument(_ name: String, _ value: String) -> String {
        String(localized: "pageInfo.error.invalidArgument", defaultValue: "Invalid \(name): \(value)", table: "PageInfo", bundle: .module)
    }
    static var noSiteInformation: String { String(localized: "pageInfo.error.noSiteInformation", defaultValue: "This page has no site information.", table: "PageInfo", bundle: .module) }
    static var notAWebPage: String { String(localized: "pageInfo.error.notAWebPage", defaultValue: "Site settings apply to web pages only.", table: "PageInfo", bundle: .module) }
    static var certificateWarningsAlreadyOn: String { String(localized: "pageInfo.error.certificateWarningsAlreadyOn", defaultValue: "Security warnings are already on for this site.", table: "PageInfo", bundle: .module) }
}
