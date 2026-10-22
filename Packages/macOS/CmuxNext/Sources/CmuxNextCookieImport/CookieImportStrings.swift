import Foundation

/// Text of Import Cookies from Browser (`browser.importCookies`): the permission card an agent's
/// run shows, its refusals, the done toast and the Cookie Imports window. Table
/// `CookieImport.xcstrings`.
enum CookieImportStrings {
    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "CookieImport", bundle: .module)
    }

    // MARK: Permission card (asking)

    static var title: String { t("cookieImport.consent.title", "An agent wants to import your cookies") }
    static var titleChief: String { t("cookieImport.consent.titleChief", "Your Chief wants to import your browser cookies") }
    static var titleProgram: String { t("cookieImport.consent.titleProgram", "A program wants to import your browser cookies") }
    static func lead(browser: String, target: String) -> String {
        String(format: t("cookieImport.consent.leadInto",
                         "It asks to copy cookies from %1$@ into the cmux browser profile “%2$@”, so pages there are signed in as in that browser."),
               browser, target)
    }
    static var requestedBy: String { t("cookieImport.consent.requestedBy", "Requested by") }
    static var reasonLabel: String { t("cookieImport.consent.reasonOwnWords", "Its reason, in its own words") }
    static var latestLabel: String { t("cookieImport.consent.latest", "What the agent said last") }
    static var fromLabel: String { t("cookieImport.consent.from", "From") }
    static var sitesLabel: String { t("cookieImport.consent.sites", "Sites") }
    static var intoLabel: String { t("cookieImport.consent.into", "Into") }
    static var allSites: String { t("cookieImport.consent.allSites", "All sites (every cookie in this profile)") }
    static var everySiteWarning: String {
        t("cookieImport.consent.everySite",
          "Every site: this signs cmux in to everything you are signed in to in that browser profile, email and banking too. Deny and ask the agent to name only the sites it needs.")
    }
    static var showAgentChat: String { t("cookieImport.consent.showChat", "Show Agent Chat") }
    static var showTerminal: String { t("cookieImport.consent.showTerminal", "Show Agent Terminal") }
    static var allowOnce: String { t("cookieImport.consent.allowOnce", "Allow Once") }
    static var deny: String { t("cookieImport.consent.deny", "Deny") }
    static func afterAllowKeychain(_ service: String) -> String {
        String(format: t("cookieImport.consent.afterAllowKeychain",
                         "After Allow, macOS asks for your Mac password so cmux can read the “%@” key. Choose Allow there, not Always Allow, so cmux has to ask again next time."),
               service)
    }
    static var afterAllowSafari: String {
        t("cookieImport.consent.afterAllowFDA", "Safari’s cookies need Full Disk Access for cmux (System Settings › Privacy & Security).")
    }
    static var afterAllowNone: String { t("cookieImport.consent.afterAllowNone", "After Allow, cmux reads the cookies at once; macOS does not ask.") }
    static var nothingLeaves: String {
        t("cookieImport.consent.nothingLeaves", "Cookies stay on this Mac, are never logged, and you can remove them later.")
    }
    static func agentChat(_ name: String) -> String { String(format: t("cookieImport.requester.agentChat", "Agent chat “%@”"), name) }
    static func homeChief(_ name: String) -> String { String(format: t("cookieImport.requester.homeChief", "Your Chief “%@” (Home)"), name) }
    static var homeChiefUnnamed: String { t("cookieImport.requester.homeChiefUnnamed", "Your Chief (Home)") }
    static func terminal(_ name: String) -> String { String(format: t("cookieImport.requester.terminal", "Terminal “%@”"), name) }
    static func inWorkspace(_ name: String) -> String { String(format: t("cookieImport.requester.inWorkspace", "in workspace %@"), name) }
    static var unknownRequester: String { t("cookieImport.requester.unknown", "A program outside cmux (no agent chat or terminal named itself)") }
    static func deadline(_ seconds: Int) -> String {
        String(format: t("cookieImport.consent.deadline", "Denied automatically after %lld s"), seconds)
    }

    // MARK: Permission card (after the answer)

    static func readingTitle(_ browser: String) -> String { String(format: t("cookieImport.card.readingTitle", "Reading cookies from %@…"), browser) }
    static func readingKeychain(_ service: String) -> String {
        String(format: t("cookieImport.card.readingKeychain",
                         "macOS is asking for your Mac password to release the “%@” key. Choose Allow, not Always Allow. Deny there stops the import and nothing is read."),
               service)
    }
    static var readingSafari: String {
        t("cookieImport.card.readingSafari", "Reading Safari’s cookies. If macOS refuses, give cmux Full Disk Access in System Settings › Privacy & Security.")
    }
    static var readingPlain: String { t("cookieImport.card.readingPlain", "Reading and copying the cookies…") }
    static func importedTitle(count: Int, browser: String) -> String { done(count: count, browser: browser) }
    static func importedLead(target: String) -> String {
        String(format: t("cookieImport.card.importedLead",
                         "They are in the cmux browser profile “%@”. Remove takes exactly these cookies out again, which signs that profile out of these sites."),
               target)
    }
    static func skipped(_ count: Int) -> String {
        String(format: t("cookieImport.card.skipped", "%lld cookies were skipped (cmux could not decrypt or store them)."), count)
    }
    static var remove: String { t("cookieImport.card.remove", "Remove") }
    static var showAll: String { t("cookieImport.card.showAll", "All Cookie Imports…") }
    static var done: String { t("cookieImport.card.done", "Done") }
    static func showSites(_ count: Int) -> String { String(format: t("cookieImport.card.showSites", "Show All %lld Sites"), count) }
    static var endedTitle: String { t("cookieImport.card.endedTitle", "Nothing was imported") }
    static var removedTitle: String { t("cookieImport.card.removedTitle", "Imported cookies removed") }
    static func removedLead(count: Int, target: String) -> String {
        String(format: t("cookieImport.card.removedLead", "Removed %1$lld cookies from the cmux browser profile “%2$@”."), count, target)
    }
    static func andMore(_ list: String, _ more: Int) -> String {
        String(format: t("cookieImport.card.andMore", "%1$@ and %2$lld more"), list, more)
    }
    static func siteCount(_ host: String, _ count: Int) -> String { String(format: t("cookieImport.card.siteCount", "%1$@ (%2$lld)"), host, count) }
    static var noSites: String { t("cookieImport.card.noSites", "No cookies were written.") }

    // MARK: Cookie Imports window

    static var windowTitle: String { t("cookieImport.window.title", "Cookie Imports") }
    static var windowLead: String {
        t("cookieImport.window.lead",
          "Every request to import cookies from another browser, who asked, why, and what came in. No cookie value is kept here.")
    }
    static var windowEmpty: String { t("cookieImport.window.empty", "No cookie imports yet.") }
    static var person: String { t("cookieImport.window.person", "You") }
    static func outcome(_ outcome: CookieImportRecord.Outcome, removed: Bool) -> String {
        if removed { return t("cookieImport.outcome.removed", "Removed") }
        return switch outcome {
        case .imported: t("cookieImport.outcome.imported", "Imported")
        case .denied: t("cookieImport.outcome.denied", "Denied")
        case .timedOut: t("cookieImport.outcome.timedOut", "No answer")
        case .nothingMatched: t("cookieImport.outcome.nothingMatched", "Nothing matched")
        case .failed: t("cookieImport.outcome.failed", "Failed")
        }
    }
    static func removedToast(_ count: Int) -> String { String(format: t("cookieImport.toast.removed", "Removed %lld imported cookies."), count) }

    // MARK: Refusals and results (the CLI prints these)

    static var reasonRequired: String {
        t("cookieImport.error.reasonRequired",
          "An agent must say why it needs the cookies: pass --reason \"<what you will do with them>\". The person sees it before anything is read.")
    }
    static func invalidSite(_ site: String) -> String {
        String(format: t("cookieImport.error.invalidSite", "“%@” is not a site name. Name sites by host, for example --domain github.com."), site)
    }
    static var denied: String { t("cookieImport.error.denied", "The person denied the cookie import. Nothing was read.") }
    static var timedOut: String { t("cookieImport.error.timedOut", "No answer to the cookie import request within the time limit. Nothing was read.") }
    static var busy: String { t("cookieImport.error.busy", "Another cookie import request is waiting for the person. Try again after it is answered.") }
    static var noWindow: String { t("cookieImport.error.noWindow", "cmux has no window to ask the person in. Nothing was read.") }
    static var unknownImport: String { t("cookieImport.error.unknownImport", "No cookie import has that id. List them with cmux browser cookie-imports.") }
    static var missingImportID: String { t("cookieImport.error.missingImportID", "Name the import: --id <id> (cmux browser cookie-imports lists them).") }
    static var alreadyRemoved: String { t("cookieImport.error.alreadyRemoved", "That import brought no cookies in, or they were already removed.") }
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
    static func done(count: Int, browser: String) -> String {
        String(format: t("cookieImport.toast.done", "Imported %1$lld cookies from %2$@."), count, browser)
    }
}
