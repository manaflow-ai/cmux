/// The browser's address bar keys (`browser.searchEngine`, `browser.omnibar.*`) and password keys
/// (`browser.passwords.*`, read live from the file root by the app; parsed here for their diagnostics).
nonisolated extension CmuxConfigSnapshot {
    static func parseBrowser(_ root: JSONValue, into snapshot: inout CmuxConfigSnapshot) {
        snapshot.browserOmnibar = BrowserOmnibarSetting.parse(root, diagnostics: &snapshot.diagnostics)
        _ = BrowserPasswordsSetting.parse(root, diagnostics: &snapshot.diagnostics)
    }
}
