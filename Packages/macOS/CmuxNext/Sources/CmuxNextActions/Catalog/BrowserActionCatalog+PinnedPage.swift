// Back to Pinned Page (cx-lle.6, Chrome's pinned tabs): a pinned tab keeps the page it was pinned on.

nonisolated extension BrowserActionCatalog {
    static func pinnedPageDescriptors() -> [ActionDescriptor] {
        // The tab menu shows it only on a pinned browser tab that browsed away from that page.
        [ActionDescriptor(
            id: "browser.resetPinnedTab",
            title: String(localized: "action.browser.resetPinnedTab", defaultValue: "Back to Pinned Page", bundle: .module),
            keywords: ["browser", "pin", "pinned", "reset", "home", "tab"],
            category: .browser, symbol: "pin.circle", surfaces: [.palette, .contextMenu],
            targets: [.tab], cliName: "browser back-to-pinned-page"
        )]
    }
}
