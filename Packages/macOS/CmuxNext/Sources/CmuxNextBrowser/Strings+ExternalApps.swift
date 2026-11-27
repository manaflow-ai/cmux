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
    /// A page's return to an app no app on this Mac opens (`BrowserPromptKind.noAppForScheme`).
    static func externalAppNone(origin: String, scheme: String) -> String {
        guard !origin.isEmpty else {
            return String(localized: "browser.externalApp.none.thisPage",
                          defaultValue: "No app on this Mac opens “\(scheme):” links.", bundle: .localizedModule)
        }
        return String(localized: "browser.externalApp.none",
                      defaultValue: "\(origin): no app on this Mac opens “\(scheme):” links.", bundle: .localizedModule)
    }
    static var externalAppOpen: String { String(localized: "browser.externalApp.open", defaultValue: "Open", bundle: .localizedModule) }
}
