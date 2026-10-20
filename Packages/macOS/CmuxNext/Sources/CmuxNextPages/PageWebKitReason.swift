public import Foundation

/// Why a cmux page shows in WebKit when `browser.defaultEngine` asks for Chromium.
///
/// Every page goes through one decision (``PageEnginePolicy``); a page that stays on WebKit names
/// one of these reasons, so the log, `cmux errors` and the debug page snapshot can say why.
public nonisolated enum PageWebKitReason: String, Sendable, Hashable, CaseIterable {
    /// The person chose WebKit (`browser.defaultEngine` is `webkit`).
    case personChoseWebKit = "setting"
    /// The page serves files it makes at run time (``PageDescriptor/dynamicPrefixes``: wallpaper
    /// thumbnails, diff patches, Markdown images and libraries). The Chromium page scheme serves only
    /// the bundled folder (`cmux_shim_page_scheme_add`), so these pages need a shim change first.
    case runtimeResources = "runtime-resources"
    /// The agent chat and New Tab page keep their warmed WebKit host until their own Chromium port:
    /// typing latency there is measured against WebKit and a spare view is kept ready.
    case agentChat = "agent-chat"
    /// The page floats over the window as a transparent panel (the update island). A Chromium page
    /// is a child window with an opaque background, which cannot float over the window's backdrop.
    case transparentOverlay = "transparent-overlay"
    /// The host adds native behavior only a WebKit page has: its own context menu items (Home's
    /// Quote in Reply and Search the Web) or file drops it opens itself (the editor). A Chromium
    /// page has neither hook yet.
    case nativeHooks = "native-hooks"
    /// Chromium is not available in this build or failed to start (``CEFUnavailableReason``).
    case chromiumUnavailable = "chromium-unavailable"
    /// The Chromium page did not start or never reached the host; the page reopened in WebKit.
    case chromiumFailed = "chromium-failed"
    /// Chromium's page scheme does not serve this page: only first-party pages
    /// (`FirstPartyPages.ids`) are registered with it, and this page is not one (changelog, CodeRouter,
    /// stats, files). Making it first-party also changes its CSP and lets it reach the daemon.
    case notServedByChromium = "not-served-by-chromium"
}
