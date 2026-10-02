import Foundation

nonisolated extension PageInfoStrings {
    // Permission names (Chromium `IDS_SITE_SETTINGS_TYPE_*`)
    // On-device site data dialog
    static var siteDataTitle: String { String(localized: "pageInfo.siteData.title", defaultValue: "On-device site data", table: "PageInfo", bundle: .module) }
    static var siteDataSubtitle: String { String(localized: "pageInfo.siteData.subtitle", defaultValue: "Sites that stored data on your device while you were on this page", table: "PageInfo", bundle: .module) }
    static var siteDataEmpty: String { String(localized: "pageInfo.siteData.empty", defaultValue: "No site data", table: "PageInfo", bundle: .module) }
    static var thisSite: String { String(localized: "pageInfo.siteData.thisSite", defaultValue: "This site", table: "PageInfo", bundle: .module) }
    static var thirdParty: String { String(localized: "pageInfo.siteData.thirdParty", defaultValue: "Third party", table: "PageInfo", bundle: .module) }
    static func cookiesOnly(_ count: Int) -> String {
        String(localized: "pageInfo.siteData.cookies", defaultValue: "Cookies: \(count)", table: "PageInfo", bundle: .module)
    }
    static var otherData: String { String(localized: "pageInfo.siteData.otherData", defaultValue: "Other site data", table: "PageInfo", bundle: .module) }
    static func deleteDataFor(_ site: String) -> String {
        String(localized: "pageInfo.siteData.deleteFor", defaultValue: "Delete data for \(site)", table: "PageInfo", bundle: .module)
    }
    static var done: String { String(localized: "pageInfo.done", defaultValue: "Done", table: "PageInfo", bundle: .module) }

    // Site settings window
    static func siteSettingsTitle(_ site: String) -> String {
        String(localized: "pageInfo.siteSettings.windowTitle", defaultValue: "Site settings: \(site)", table: "PageInfo", bundle: .module)
    }
    static var usage: String { String(localized: "pageInfo.siteSettings.usage", defaultValue: "Usage", table: "PageInfo", bundle: .module) }
    static var permissions: String { String(localized: "pageInfo.siteSettings.permissions", defaultValue: "Permissions", table: "PageInfo", bundle: .module) }
    static var deleteData: String { String(localized: "pageInfo.siteSettings.deleteData", defaultValue: "Delete data", table: "PageInfo", bundle: .module) }
    static var engineLimited: String { String(localized: "pageInfo.siteSettings.engineLimited", defaultValue: "Only the permissions this browser engine can enforce are listed.", table: "PageInfo", bundle: .module) }

    // Certificate viewer (General and Details tabs)
    static func viewerTitle(_ name: String) -> String {
        String(localized: "pageInfo.viewer.title", defaultValue: "Certificate Viewer: \(name)", table: "PageInfo", bundle: .module)
    }
    static var general: String { String(localized: "pageInfo.viewer.general", defaultValue: "General", table: "PageInfo", bundle: .module) }
    static var details: String { String(localized: "pageInfo.viewer.details", defaultValue: "Details", table: "PageInfo", bundle: .module) }
    static var issuedTo: String { String(localized: "pageInfo.viewer.issuedTo", defaultValue: "Issued To", table: "PageInfo", bundle: .module) }
    static var issuedBy: String { String(localized: "pageInfo.viewer.issuedBy", defaultValue: "Issued By", table: "PageInfo", bundle: .module) }
    static var validityPeriod: String { String(localized: "pageInfo.viewer.validity", defaultValue: "Validity Period", table: "PageInfo", bundle: .module) }
    static var fingerprints: String { String(localized: "pageInfo.viewer.fingerprints", defaultValue: "SHA-256 Fingerprints", table: "PageInfo", bundle: .module) }
    static var commonName: String { String(localized: "pageInfo.viewer.cn", defaultValue: "Common Name (CN)", table: "PageInfo", bundle: .module) }
    static var organization: String { String(localized: "pageInfo.viewer.o", defaultValue: "Organization (O)", table: "PageInfo", bundle: .module) }
    static var organizationalUnit: String { String(localized: "pageInfo.viewer.ou", defaultValue: "Organizational Unit (OU)", table: "PageInfo", bundle: .module) }
    static var issuedOn: String { String(localized: "pageInfo.viewer.issuedOn", defaultValue: "Issued On", table: "PageInfo", bundle: .module) }
    static var expiresOn: String { String(localized: "pageInfo.viewer.expiresOn", defaultValue: "Expires On", table: "PageInfo", bundle: .module) }
    static var certificate: String { String(localized: "pageInfo.viewer.certificate", defaultValue: "Certificate", table: "PageInfo", bundle: .module) }
    static var publicKey: String { String(localized: "pageInfo.viewer.publicKey", defaultValue: "Public Key", table: "PageInfo", bundle: .module) }
    static var notPartOfCertificate: String { String(localized: "pageInfo.viewer.notPart", defaultValue: "<Not part of certificate>", table: "PageInfo", bundle: .module) }
    static var hierarchy: String { String(localized: "pageInfo.viewer.hierarchy", defaultValue: "Certificate Hierarchy", table: "PageInfo", bundle: .module) }
    static var fields: String { String(localized: "pageInfo.viewer.fields", defaultValue: "Certificate Fields", table: "PageInfo", bundle: .module) }
    static var fieldValue: String { String(localized: "pageInfo.viewer.fieldValue", defaultValue: "Field Value", table: "PageInfo", bundle: .module) }
    static var export: String { String(localized: "pageInfo.viewer.export", defaultValue: "Export…", table: "PageInfo", bundle: .module) }
    static var version: String { String(localized: "pageInfo.viewer.version", defaultValue: "Version", table: "PageInfo", bundle: .module) }
    static var serialNumber: String { String(localized: "pageInfo.viewer.serial", defaultValue: "Serial Number", table: "PageInfo", bundle: .module) }
    static var signatureAlgorithm: String { String(localized: "pageInfo.viewer.signatureAlgorithm", defaultValue: "Certificate Signature Algorithm", table: "PageInfo", bundle: .module) }
    static var issuer: String { String(localized: "pageInfo.viewer.issuer", defaultValue: "Issuer", table: "PageInfo", bundle: .module) }
    static var notBefore: String { String(localized: "pageInfo.viewer.notBefore", defaultValue: "Not Before", table: "PageInfo", bundle: .module) }
    static var notAfter: String { String(localized: "pageInfo.viewer.notAfter", defaultValue: "Not After", table: "PageInfo", bundle: .module) }
    static var subject: String { String(localized: "pageInfo.viewer.subject", defaultValue: "Subject", table: "PageInfo", bundle: .module) }
    static var publicKeyAlgorithm: String { String(localized: "pageInfo.viewer.publicKeyAlgorithm", defaultValue: "Subject Public Key Algorithm", table: "PageInfo", bundle: .module) }
    static var alternativeNames: String { String(localized: "pageInfo.viewer.san", defaultValue: "Subject Alternative Names", table: "PageInfo", bundle: .module) }
    static var sha1Fingerprint: String { String(localized: "pageInfo.viewer.sha1", defaultValue: "SHA-1 Fingerprint", table: "PageInfo", bundle: .module) }
    static var sha256Fingerprint: String { String(localized: "pageInfo.viewer.sha256", defaultValue: "SHA-256 Fingerprint", table: "PageInfo", bundle: .module) }
    static var noCertificate: String { String(localized: "pageInfo.viewer.none", defaultValue: "No certificate is available for this page.", table: "PageInfo", bundle: .module) }
    static func verificationFailed(_ reason: String) -> String {
        String(localized: "pageInfo.viewer.failed", defaultValue: "Verification failed: \(reason)", table: "PageInfo", bundle: .module)
    }

    // Action refusals
    static func invalidArgument(_ name: String, _ value: String) -> String {
        String(localized: "pageInfo.error.invalidArgument", defaultValue: "Invalid \(name): \(value)", table: "PageInfo", bundle: .module)
    }
    static var noSiteInformation: String { String(localized: "pageInfo.error.noSiteInformation", defaultValue: "This page has no site information.", table: "PageInfo", bundle: .module) }
    static var notAWebPage: String { String(localized: "pageInfo.error.notAWebPage", defaultValue: "Site settings apply to web pages only.", table: "PageInfo", bundle: .module) }
}
