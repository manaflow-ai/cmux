/// Browser engine defaults for previews and hosts without Chromium.
public extension SettingsHostActions {
    /// Whether this build includes the Chromium runtime. Hosts without it
    /// hide the Browser Engine row unless the setting already asks for Chromium.
    func isChromiumBrowserEngineBundled() -> Bool { false }

    /// Hosts without Chromium have no extensions page to open.
    func openBrowserExtensionsManagement() {}
}
