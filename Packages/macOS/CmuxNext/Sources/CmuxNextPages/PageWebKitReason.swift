public import Foundation

/// Why a cmux page shows in WebKit when `browser.defaultEngine` asks for Chromium.
///
/// Every page goes through one decision (``PageEnginePolicy``); a page that stays on WebKit names
/// one of these reasons, so the log, `cmux errors` and the debug page snapshot can say why.
public nonisolated enum PageWebKitReason: String, Sendable, Hashable, CaseIterable {
    /// The person chose WebKit (`browser.defaultEngine` is `webkit`).
    case personChoseWebKit = "setting"
    /// The agent chat and New Tab page keep their warmed WebKit host until their own Chromium port:
    /// typing latency there is measured against WebKit and a spare view is kept ready.
    case agentChat = "agent-chat"
    /// The page floats over the window as a transparent panel (the update island, the icon
    /// picker's glass panel). A Chromium page is an opaque child window that takes the keys, which
    /// cannot float over the window's backdrop or keep a panel that closes when it loses them.
    case transparentOverlay = "transparent-overlay"
    /// The host adds native behavior only a WebKit page has: its own context menu items (Home's
    /// Quote in Reply and Search the Web) or file drops it opens itself (the editor). A Chromium
    /// page has neither hook yet.
    case nativeHooks = "native-hooks"
    /// Chromium is not available in this build or failed to start (``CEFUnavailableReason``).
    case chromiumUnavailable = "chromium-unavailable"
    /// The Chromium page did not start or never reached the host; the page reopened in WebKit.
    case chromiumFailed = "chromium-failed"
    /// Chromium's page scheme does not serve this page: only the pages the app ships are registered
    /// with it (CmuxNextApp `FirstPartyPageSchemes.descriptors`), and this page is not one.
    case notServedByChromium = "not-served-by-chromium"
    /// `web-dev.json` points cmux's pages at a dev server or an overlay (``WebDevOverride``). Only
    /// the WebKit scheme handler reads it: Chromium serves the bundled folder it was handed at
    /// start, so a page there would never show the edit.
    case liveWebOverride = "live-web-override"
}
