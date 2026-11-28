#if DEBUG
import AppKit
import CmuxNextBrowser
import CmuxNextSettings

/// `debug.browser_import_offer` (DEBUG builds): drives the browser-data
/// import offer through its service, the same methods the card's buttons call.
///
/// `action`: `state` (default), `show` (on browser tab `tab`, else the
/// first one on screen, skipping the once-per-launch and state checks),
/// `answer` (`choice`: import, not_now), `reset` (a fresh Mac).
@MainActor
enum DebugBrowserImportOffer {
    static func run(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let offer = services.onboarding.browserImportOffer
        switch params["action"]?.stringValue ?? "state" {
        case "show":
            guard let entry = target(params["tab"]?.stringValue, services) else { return .object(["error": .string("no browser tab on screen")]) }
            // Shown once the installed browsers are known (at once after the first search).
            offer.findBrowsers { [weak offer, weak entry] found in
                if let entry { offer?.show(on: entry.chrome, browsers: found) }
            }
        case "answer":
            let choices: [String: BrowserCookieImportChoice] = ["import": .importCookies, "not_now": .notNow]
            guard let choice = params["choice"]?.stringValue.flatMap({ choices[$0] }) else { return .object(["error": .string("choice: import or not_now")]) }
            // Answered from the card on screen: Import then targets that tab's profile.
            let shown = services.cache.browsers.values.first { $0.chrome.showsCookieImportOffer }
            for entry in services.cache.browsers.values { entry.chrome.hideCookieImportOffer() }
            offer.answer(choice, profile: shown.map { BrowserProfileRecord.wireID(for: $0.tab.profileID) })
        case "reset": offer.reset()
        default: break
        }
        return state(services)
    }

    private static func target(_ key: String?, _ services: AppServices) -> BrowserEntry? {
        if let key { return services.cache.existingBrowser(key) }
        return services.cache.browsers.values.first { $0.chrome.window != nil && !$0.chrome.isHiddenOrHasHiddenAncestor }
    }

    private static func state(_ services: AppServices) -> JSONValue {
        let offer = services.onboarding.browserImportOffer
        let shownOn = services.cache.browsers.filter { $0.value.chrome.showsCookieImportOffer }.map(\.key).sorted()
        return .object([
            "dismissed": .bool(offer.state.dismissed),
            "imported": .bool(offer.state.imported),
            "shown_this_launch": .bool(offer.shownThisLaunch),
            "shown_on": .array(shownOn.map(JSONValue.string)),
            "browsers": offer.browsers.map { found in JSONValue.array(found.map { JSONValue.string($0.browser.displayName) }) } ?? .null,
        ])
    }
}
#endif
