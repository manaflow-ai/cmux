#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextBrowser
import CmuxNextSettings

/// `debug.browser_import_offer` (DEBUG builds): drives the browser-data
/// import offer through its service, the same methods the card's buttons call.
///
/// `action`: `state` (default), `show` (on browser tab `tab`, else the
/// first one on screen, skipping the once-per-launch and state checks),
/// `answer` (`choice`: import, not_now, never), `reset` (a fresh Mac, the banner setting on).
@MainActor
enum DebugBrowserImportOffer {
    static func run(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let offer = services.onboarding.browserImportOffer
        switch params["action"]?.stringValue ?? "state" {
        case "show":
            guard let entry = target(params["tab"]?.stringValue, services) else { return .object(["error": .string("no browser tab on screen")]) }
            // Shown once the installed browsers are known (at once after the first search).
            offer.finder.find { [weak offer, weak entry] found in
                if let chrome = entry?.chrome { offer?.show(on: chrome, browsers: found) }
            }
        case "answer":
            let choices: [String: BrowserCookieImportChoice] = ["import": .importCookies, "not_now": .notNow, "never": .never]
            guard let choice = params["choice"]?.stringValue.flatMap({ choices[$0] }) else { return .object(["error": .string("choice: import, not_now or never")]) }
            // Answered from the card on screen: Import then targets that tab's profile.
            let shown = services.cache.browsers.values.first { $0.chrome?.showsCookieImportOffer == true }
            for entry in services.cache.browsers.values { entry.chrome?.hideCookieImportOffer() }
            offer.answer(choice, profile: shown.map { BrowserProfileRecord.wireID(for: $0.tab.profileID) })
        case "reset": offer.reset()
        default: break
        }
        return offer.readout()
    }

    private static func target(_ key: String?, _ services: AppServices) -> BrowserEntry? {
        if let key { return services.cache.existingBrowser(key) }
        return services.cache.browsers.values.first { $0.chrome.map { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor } == true }
    }

}
#endif
