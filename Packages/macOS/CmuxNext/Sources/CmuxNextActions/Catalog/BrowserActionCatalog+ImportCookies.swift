// Import Cookies from Browser: one browser profile's cookies into a cmux browser profile, for the
// CLI and agents (`cmux browser import-cookies --from chrome:Work --domain github.com --reason …`).
// A person's run (palette) imports at once; any other run first shows the person a consent panel
// that names the agent and its reason, and only an Allow there reads the other browser's data.

nonisolated extension BrowserActionCatalog {
    static func importCookiesDescriptors() -> [ActionDescriptor] {
        var importCookies = ActionDescriptor(
            id: "browser.importCookies",
            title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.browser.importCookies") + "\u{E002}" + String(localized: "action.browser.importCookies", defaultValue: "Import Cookies from Browser…", bundle: .module)),
            keywords: ["browser", "import", "cookies", "sign in", "login", "session", "chrome", "arc", "brave", "edge", "helium",
                       "dia", "firefox", "safari"],
            category: .browser, symbol: "square.and.arrow.down",
            surfaces: [.palette],
            arguments: [
                ActionArgument(name: "from", title: ("\u{E000}Localizable\u{E001}" + String(describing: "argument.browser.importCookies.from") + "\u{E002}" + String(localized: "argument.browser.importCookies.from", defaultValue: "From Browser",
                                                           bundle: .module)), kind: .string),
                ActionArgument(name: "domain", title: ("\u{E000}Localizable\u{E001}" + String(describing: "argument.browser.importCookies.domain") + "\u{E002}" + String(localized: "argument.browser.importCookies.domain", defaultValue: "Sites",
                                                             bundle: .module)), kind: .string, isRequired: false),
                ActionArgument(name: "reason", title: ("\u{E000}Localizable\u{E001}" + String(describing: "argument.browser.importCookies.reason") + "\u{E002}" + String(localized: "argument.browser.importCookies.reason", defaultValue: "Reason",
                                                             bundle: .module)), kind: .string, isRequired: false),
                ActionArgument(name: "profile", title: ("\u{E000}Localizable\u{E001}" + String(describing: "argument.browser.importCookies.profile") + "\u{E002}" + String(localized: "argument.browser.importCookies.profile", defaultValue: "Into Browser Profile",
                                                              bundle: .module)), kind: .target(.browserProfile), isRequired: false),
            ],
            cliName: "browser import-cookies",
            surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
        )
        // The person answers the consent panel and macOS's Keychain prompt: the run waits for both.
        importCookies.waitsForPerson = true
        return [importCookies]
    }
}
