// Import Cookies from Browser: one browser profile's cookies into a cmux browser profile, for the
// CLI and agents (`cmux browser import-cookies --from chrome:Work --domain github.com --reason …`).
// A person's run (palette) imports at once; any other run first shows the person a consent panel
// that names the agent and its reason, and only an Allow there reads the other browser's data.

nonisolated extension BrowserActionCatalog {
    static func importCookiesDescriptors() -> [ActionDescriptor] {
        var importCookies = ActionDescriptor(
            id: "browser.importCookies",
            title: String(localized: "action.browser.importCookies", defaultValue: "Import Cookies from Browser…", bundle: .module),
            keywords: ["browser", "import", "cookies", "sign in", "login", "session", "chrome", "arc", "brave", "edge", "helium",
                       "dia", "firefox", "safari"],
            category: .browser, symbol: "square.and.arrow.down",
            surfaces: [.palette],
            arguments: [
                ActionArgument(name: "from", title: String(localized: "argument.browser.importCookies.from", defaultValue: "From Browser",
                                                           bundle: .module), kind: .string),
                ActionArgument(name: "domain", title: String(localized: "argument.browser.importCookies.domain", defaultValue: "Sites",
                                                             bundle: .module), kind: .string, isRequired: false),
                ActionArgument(name: "reason", title: String(localized: "argument.browser.importCookies.reason", defaultValue: "Reason",
                                                             bundle: .module), kind: .string, isRequired: false),
                ActionArgument(name: "profile", title: String(localized: "argument.browser.importCookies.profile", defaultValue: "Into Browser Profile",
                                                              bundle: .module), kind: .target(.browserProfile), isRequired: false),
            ],
            cliName: "browser import-cookies",
            surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
        )
        // The person answers the consent panel and macOS's Keychain prompt: the run waits for both.
        importCookies.waitsForPerson = true
        // What came in and from where: a person's run opens the Cookie Imports window (who asked,
        // why, the sites, Remove); the CLI and agents get the audit list and the browsers on this
        // Mac (`cmux browser cookie-imports`), sites and counts only, never a cookie.
        let cookieImports = ActionDescriptor(
            id: "browser.cookieImports",
            title: String(localized: "action.browser.cookieImports", defaultValue: "Show Cookie Imports", bundle: .module),
            keywords: ["browser", "cookies", "imported", "import", "audit", "remove", "revoke", "sign in", "agent"],
            category: .browser, symbol: "list.bullet.rectangle",
            surfaces: [.palette],
            cliName: "browser cookie-imports",
            surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
        )
        // Takes one import's cookies back out of its cmux profile (`--id` from `browser cookie-imports`);
        // the Cookie Imports window and the finished card offer the same Remove.
        let removeImported = ActionDescriptor(
            id: "browser.removeImportedCookies",
            title: String(localized: "action.browser.removeImportedCookies", defaultValue: "Remove Imported Cookies", bundle: .module),
            keywords: ["browser", "cookies", "imported", "remove", "revoke", "sign out"],
            category: .browser, symbol: "trash",
            surfaces: [.keyboard],
            arguments: [
                ActionArgument(name: "id", title: String(localized: "argument.browser.removeImportedCookies.id", defaultValue: "Import",
                                                         bundle: .module), kind: .string),
            ],
            cliName: "browser remove-imported-cookies",
            surfacePlan: ActionSurfacePlan(palette: .exempt(.noObject), cli: .offered, contextMenuExemption: .noObject)
        )
        return [importCookies, cookieImports, removeImported]
    }
}
