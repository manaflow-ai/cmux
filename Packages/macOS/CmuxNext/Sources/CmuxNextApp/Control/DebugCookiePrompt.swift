#if DEBUG
import AppKit
import CmuxNextBrowser
import CmuxNextSettings

/// `debug.cookie_prompt` (DEBUG builds): drives the cookie import card
/// through its service, the same methods the card's buttons call.
///
/// `action`: `state` (default), `show` (on browser tab `tab`, else the
/// first one on screen, skipping the once-per-launch and state checks),
/// `answer` (`choice`: import, not_now, never), `reset` (a fresh Mac).
@MainActor
enum DebugCookiePrompt {
    static func run(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let prompt = services.onboarding.cookiePrompt
        switch params["action"]?.stringValue ?? "state" {
        case "show":
            guard let entry = target(params["tab"]?.stringValue, services) else { return .object(["error": .string("no browser tab on screen")]) }
            // Shown once the installed browsers are known (at once after the first search).
            prompt.findBrowsers { [weak prompt, weak entry] found in
                if let entry { prompt?.show(on: entry.chrome, browsers: found) }
            }
        case "answer":
            let choices: [String: BrowserCookieImportChoice] = ["import": .importCookies, "not_now": .notNow, "never": .never]
            guard let choice = params["choice"]?.stringValue.flatMap({ choices[$0] }) else { return .object(["error": .string("choice: import, not_now or never")]) }
            for entry in services.cache.browsers.values { entry.chrome.hideCookieImportOffer() }
            prompt.answer(choice)
        case "reset": prompt.reset()
        default: break
        }
        return state(services)
    }

    private static func target(_ key: String?, _ services: AppServices) -> BrowserEntry? {
        if let key { return services.cache.existingBrowser(key) }
        return services.cache.browsers.values.first { $0.chrome.window != nil && !$0.chrome.isHiddenOrHasHiddenAncestor }
    }

    private static func state(_ services: AppServices) -> JSONValue {
        let prompt = services.onboarding.cookiePrompt
        let shownOn = services.cache.browsers.filter { $0.value.chrome.showsCookieImportOffer }.map(\.key).sorted()
        return .object([
            "never_show": .bool(prompt.state.neverShow),
            "imported": .bool(prompt.state.imported),
            "snoozed_until": prompt.state.snoozedUntil.map { JSONValue.string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
            "shown_this_launch": .bool(prompt.shownThisLaunch),
            "shown_on": .array(shownOn.map(JSONValue.string)),
            "browsers": prompt.browsers.map { found in JSONValue.array(found.map { JSONValue.string($0.browser.displayName) }) } ?? .null,
        ])
    }
}
#endif
