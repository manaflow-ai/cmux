import Foundation

// A page's link to another app, asked in the prompt bar (BrowserExternalApps).
extension Strings {
    static func externalAppPrompt(origin: String, app: String) -> String {
        guard !origin.isEmpty else {
            return String(localized: "browser.externalApp.prompt.thisPage", defaultValue: "This page wants to open “\(app)”.", bundle: .localizedModule)
        }
        return String(localized: "browser.externalApp.prompt", defaultValue: "\(origin) wants to open “\(app)”.", bundle: .localizedModule)
    }
    static var externalAppAlwaysAllow: String {
        String(localized: "browser.externalApp.alwaysAllow", defaultValue: "Always allow on this site", bundle: .localizedModule)
    }
    static var externalAppOpen: String { String(localized: "browser.externalApp.open", defaultValue: "Open", bundle: .localizedModule) }
}
