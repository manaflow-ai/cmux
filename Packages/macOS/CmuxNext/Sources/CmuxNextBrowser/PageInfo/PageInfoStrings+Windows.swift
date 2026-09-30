import Foundation

nonisolated extension PageInfoStrings {
    // Permission names (Chromium `IDS_SITE_SETTINGS_TYPE_*`)
    static func name(_ kind: SitePermissionKind) -> String {
        switch kind {
        case .location: String(localized: "pageInfo.permission.location", defaultValue: "Location", table: "PageInfo", bundle: .module)
        case .camera: String(localized: "pageInfo.permission.camera", defaultValue: "Camera", table: "PageInfo", bundle: .module)
        case .microphone: String(localized: "pageInfo.permission.microphone", defaultValue: "Microphone", table: "PageInfo", bundle: .module)
        case .notifications: String(localized: "pageInfo.permission.notifications", defaultValue: "Notifications", table: "PageInfo", bundle: .module)
        case .javascript: String(localized: "pageInfo.permission.javascript", defaultValue: "JavaScript", table: "PageInfo", bundle: .module)
        case .images: String(localized: "pageInfo.permission.images", defaultValue: "Images", table: "PageInfo", bundle: .module)
        case .popups: String(localized: "pageInfo.permission.popups", defaultValue: "Pop-ups and redirects", table: "PageInfo", bundle: .module)
        case .sound: String(localized: "pageInfo.permission.sound", defaultValue: "Sound", table: "PageInfo", bundle: .module)
        case .automaticDownloads: String(localized: "pageInfo.permission.automaticDownloads", defaultValue: "Automatic downloads", table: "PageInfo", bundle: .module)
        case .midi: String(localized: "pageInfo.permission.midi", defaultValue: "MIDI device control & reprogram", table: "PageInfo", bundle: .module)
        case .usb: String(localized: "pageInfo.permission.usb", defaultValue: "USB devices", table: "PageInfo", bundle: .module)
        case .serial: String(localized: "pageInfo.permission.serial", defaultValue: "Serial ports", table: "PageInfo", bundle: .module)
        case .hid: String(localized: "pageInfo.permission.hid", defaultValue: "HID devices", table: "PageInfo", bundle: .module)
        case .clipboard: String(localized: "pageInfo.permission.clipboard", defaultValue: "Clipboard", table: "PageInfo", bundle: .module)
        }
    }

    /// Chrome's "Can ask to …" state text for a permission at its ask default.
    static func askText(_ kind: SitePermissionKind) -> String? {
        switch kind {
        case .location: String(localized: "pageInfo.ask.location", defaultValue: "Can ask for your location", table: "PageInfo", bundle: .module)
        case .camera: String(localized: "pageInfo.ask.camera", defaultValue: "Can ask to use your camera", table: "PageInfo", bundle: .module)
        case .microphone: String(localized: "pageInfo.ask.microphone", defaultValue: "Can ask to use your microphone", table: "PageInfo", bundle: .module)
        case .notifications: String(localized: "pageInfo.ask.notifications", defaultValue: "Can ask to send notifications", table: "PageInfo", bundle: .module)
        case .automaticDownloads: String(localized: "pageInfo.ask.automaticDownloads", defaultValue: "Can ask to automatically download multiple files", table: "PageInfo", bundle: .module)
        case .midi: String(localized: "pageInfo.ask.midi", defaultValue: "Can ask to control and reprogram your MIDI devices", table: "PageInfo", bundle: .module)
        case .usb: String(localized: "pageInfo.ask.usb", defaultValue: "Can ask to connect to USB devices", table: "PageInfo", bundle: .module)
        case .serial: String(localized: "pageInfo.ask.serial", defaultValue: "Can ask to connect to serial ports", table: "PageInfo", bundle: .module)
        case .hid: String(localized: "pageInfo.ask.hid", defaultValue: "Can ask to connect to HID devices", table: "PageInfo", bundle: .module)
        case .clipboard: String(localized: "pageInfo.ask.clipboard", defaultValue: "Can ask to see text and images on your clipboard", table: "PageInfo", bundle: .module)
        case .javascript, .images, .popups, .sound: nil
        }
    }

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

    // Certificate viewer (Chrome's viewer, General and Details)
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
