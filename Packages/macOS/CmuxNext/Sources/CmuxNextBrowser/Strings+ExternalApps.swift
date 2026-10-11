import Foundation

// A page's link to another app, asked in the prompt bar (BrowserExternalApps).
extension Strings {
    static func externalAppPrompt(origin: String, app: String) -> String {
        guard !origin.isEmpty else {
            return String(localized: "browser.externalApp.prompt.thisPage", defaultValue: "This page wants to open “\(app)”.", bundle: .module)
        }
        return String(localized: "browser.externalApp.prompt", defaultValue: "\(origin) wants to open “\(app)”.", bundle: .module)
    }
    static func externalAppAlwaysAllow(origin: String, scheme: String) -> String {
        guard !origin.isEmpty else {
            return String(localized: "browser.externalApp.alwaysAllow.thisPage", defaultValue: "Always allow \(scheme): links", bundle: .module)
        }
        return String(localized: "browser.externalApp.alwaysAllow", defaultValue: "Always allow \(origin) to open \(scheme): links", bundle: .module)
    }
    static var externalAppOpen: String { String(localized: "browser.externalApp.open", defaultValue: "Open", bundle: .module) }
}
