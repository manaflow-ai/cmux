import CmuxNextCompat
import Foundation

/// Text of Import Cookies from Browser (`browser.importCookies`): the consent
/// panel an agent's run shows, its refusals, and the done toast. Table
/// `CookieImport.xcstrings`.
enum CookieImportStrings {
    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "CookieImport", bundle: .module)
    }

    // MARK: Consent panel

    static var title: String { t("cookieImport.consent.title", "An agent wants to import your cookies") }
    static func lead(browser: String) -> String {
        String(format: t("cookieImport.consent.lead",
                         "It asks to copy your %@ cookies into the cmux browser, so its tabs are signed in like that browser."), browser)
    }
    static var requestedBy: String { t("cookieImport.consent.requestedBy", "Requested by") }
    static var reasonLabel: String { t("cookieImport.consent.reason", "The agent’s reason") }
    static var latestLabel: String { t("cookieImport.consent.latest", "What the agent said last") }
    static var fromLabel: String { t("cookieImport.consent.from", "From") }
    static var sitesLabel: String { t("cookieImport.consent.sites", "Sites") }
    static var intoLabel: String { t("cookieImport.consent.into", "Into") }
    static var allSites: String { t("cookieImport.consent.allSites", "All sites (every cookie in this profile)") }
    static var showAgentChat: String { t("cookieImport.consent.showChat", "Show Agent Chat") }
    static var showTerminal: String { t("cookieImport.consent.showTerminal", "Show Agent Terminal") }
    static var allow: String { t("cookieImport.consent.allow", "Allow") }
    static var deny: String { t("cookieImport.consent.deny", "Deny") }
    static var afterAllow: String {
        t("cookieImport.consent.afterAllow", "After Allow, macOS asks for your password to unlock the browser’s cookies. Nothing leaves this Mac.")
    }
    static var afterAllowSafari: String {
        t("cookieImport.consent.afterAllowSafari", "Safari’s cookies need Full Disk Access for cmux in System Settings. Nothing leaves this Mac.")
    }
    static func agentChat(_ name: String) -> String { String(format: t("cookieImport.requester.agentChat", "Agent chat “%@”"), name) }
    static func terminal(_ name: String) -> String { String(format: t("cookieImport.requester.terminal", "Terminal “%@”"), name) }
    static func inWorkspace(_ name: String) -> String { String(format: t("cookieImport.requester.inWorkspace", "in workspace %@"), name) }
    static var unknownRequester: String { t("cookieImport.requester.unknown", "A program outside cmux (no agent chat or terminal named itself)") }
    static func deadline(_ seconds: Int,
                         preferredLocalizations: [String] = Bundle.module.preferredLocalizations, locale: Locale = .current) -> String {
        Bundle.module.localizedString(forKey: "cookieImport.consent.deadline",
                                      value: "Denied automatically after %@",
                                      table: "CookieImport",
                                      arguments: [.duration(.seconds(seconds), units: [.seconds])],
                                      preferredLocalizations: preferredLocalizations, locale: locale)
    }

    // MARK: Refusals and results (the CLI prints these)

    static var reasonRequired: String {
        t("cookieImport.error.reasonRequired",
          "An agent must say why it needs the cookies: pass --reason \"<what you will do with them>\". The person sees it before anything is read.")
    }
    static var denied: String { t("cookieImport.error.denied", "The person denied the cookie import. Nothing was read.") }
    static var timedOut: String { t("cookieImport.error.timedOut", "No answer to the cookie import request within the time limit. Nothing was read.") }
    static var busy: String { t("cookieImport.error.busy", "Another cookie import request is waiting for the person. Try again after it is answered.") }
    static var noWindow: String { t("cookieImport.error.noWindow", "cmux has no window to ask the person in. Nothing was read.") }
    static func unknownBrowser(_ name: String, known: [String]) -> String {
        String(format: t("cookieImport.error.unknownBrowser", "No browser named “%1$@” is on this Mac. Found: %2$@."), name,
               known.isEmpty ? "-" : known.joined(separator: ", "))
    }
    static func unknownProfile(_ browser: String, _ profile: String, known: [String]) -> String {
        String(format: t("cookieImport.error.unknownProfile", "%1$@ has no profile named “%2$@”. Profiles: %3$@."), browser, profile,
               known.isEmpty ? "-" : known.joined(separator: ", "))
    }
    static func unsupported(_ browser: String) -> String {
        String(format: t("cookieImport.error.unsupported", "cmux cannot read %@’s cookies."), browser)
    }
    static var missingSource: String { t("cookieImport.error.missingSource", "Name the browser: --from <browser>[:<profile>], for example --from chrome:Work.") }
    static func failed(_ detail: String) -> String { String(format: t("cookieImport.error.failed", "The cookie import failed: %@"), detail) }
    static func keyNotFound(_ service: String) -> String {
        String(format: t("cookieImport.error.keyNotFound", "the Keychain has no item “%@”"), service)
    }
    static var keychainDenied: String { t("cookieImport.error.keychainDenied", "the macOS password prompt was denied") }
    static var needsFullDiskAccess: String {
        t("cookieImport.error.needsFullDiskAccess", "cmux needs Full Disk Access (System Settings › Privacy & Security) to read Safari’s cookies")
    }
    static var nothingMatched: String { t("cookieImport.error.nothingMatched", "No cookie in that profile matches those sites. Nothing was imported.") }
    static func done(count: Int, browser: String,
                     preferredLocalizations: [String] = Bundle.module.preferredLocalizations, locale: Locale = .current) -> String {
        Bundle.module.localizedString(forKey: "cookieImport.toast.done", value: "Cookies imported from %2$@: %1$lld.", table: "CookieImport",
                                      arguments: [.count(count), .text(browser)],
                                      preferredLocalizations: preferredLocalizations, locale: locale)
    }
}
