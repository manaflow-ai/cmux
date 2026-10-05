// The certificate warning page's controls (a WebKit tab's interstitial:
// Proceed and Go Back). Titles live in PageInfoActions.xcstrings. Ids match
// CertificateWarningCommand in CmuxNextBrowser; both buttons run these.
// No CLI verb, so no MCP tool: an agent never proceeds past a certificate
// warning by name (`cmux action run` still reaches them).

nonisolated enum CertificateWarningActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "browser.certificateWarning.proceed",
                title: t("action.certificateWarning.proceed", "Proceed Past Certificate Warning (Unsafe)"),
                keywords: ["certificate", "warning", "interstitial", "proceed", "unsafe", "tls", "ssl", "visit", "continue"],
                category: .browser, symbol: "exclamationmark.triangle", surfaces: [.palette, .keyboard],
                requires: [.browserFocused], targets: [.pane], surfacePlan: plan
            ),
            ActionDescriptor(
                id: "browser.certificateWarning.goBack",
                title: t("action.certificateWarning.goBack", "Go Back from Certificate Warning"),
                keywords: ["certificate", "warning", "interstitial", "back", "safety", "tls", "ssl"],
                category: .browser, symbol: "chevron.backward", surfaces: [.palette, .keyboard],
                requires: [.browserFocused], targets: [.pane], surfacePlan: plan
            ),
        ]
    }

    /// No CLI verb (so no MCP tool): the user decides at the warning page.
    /// No right-click menu: the warning page is a native view with its own
    /// two buttons.
    private static var plan: ActionSurfacePlan { ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .noTargetSurface) }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "PageInfoActions", bundle: .module)
    }
}
