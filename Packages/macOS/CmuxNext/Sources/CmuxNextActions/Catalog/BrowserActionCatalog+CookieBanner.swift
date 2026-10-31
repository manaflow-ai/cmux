// Show Import Cookies Banner: turns `browser.import.cookieBanner` back on after Don't Show Again, so
// the person's next browser page offers to import cookies again. It reads no browser data: the card
// it brings back imports only when the person clicks Import.

nonisolated extension BrowserActionCatalog {
    static func cookieBannerDescriptors() -> [ActionDescriptor] {
        [ActionDescriptor(
            id: "browser.showCookieImportBanner",
            title: String(localized: "action.browser.showCookieImportBanner", defaultValue: "Show Import Cookies Banner", bundle: .module),
            keywords: ["browser", "import", "cookies", "banner", "card", "offer", "sign in", "login", "reset", "dismissed", "show again"],
            category: .browser, symbol: "key",
            surfaces: [.palette],
            cliName: "browser show-cookie-banner",
            surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
        )]
    }
}
