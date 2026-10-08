#if DEBUG
import AppKit
import CmuxNextBrowser

/// `debug.cookie_prompt` (DEBUG builds): drives the cookie import card
/// through its service, the same methods the card's buttons call.
///
/// `action`: `state` (default), `show` (on browser tab `tab`, else the
/// first one on screen, skipping the once-per-launch and state checks),
/// `answer` (`choice`: import, not_now, never), `reset` (a fresh Mac).
@MainActor
enum DebugCookiePrompt {
    static func run(_ params: [String: JSONValue], _ services: AppServices?) async -> JSONValue {
        guard let services else { return .null }
        let prompt = services.onboarding.cookiePrompt
        switch params["action"]?.stringValue ?? "state" {
        case "show":
            guard let entry = target(params["tab"]?.stringValue, services) else { return .object(["error": .string("no browser tab on screen")]) }
            let browsers = await withCheckedContinuation { continuation in prompt.findBrowsers { continuation.resume(returning: $0) } }
            prompt.show(on: entry.chrome, browsers: browsers)
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
            "snoozed_until": prompt.state.snoozedUntil.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
            "shown_this_launch": .bool(prompt.shownThisLaunch),
            "shown_on": .array(shownOn.map(JSONValue.string)),
            "browsers": prompt.browsers.map { .array($0.map { .string($0.browser.displayName) }) } ?? .null,
        ])
    }
}
#endif
