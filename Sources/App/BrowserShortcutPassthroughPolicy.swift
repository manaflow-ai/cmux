import AppKit

/// Per-URL Cmd-modifier passthrough for the embedded browser pane.
///
/// When the focused browser pane's URL matches the user-configured
/// `browser.shortcutPassthroughHosts` allowlist, Cmd-modifier key equivalents
/// should be handed off to the web content instead of being claimed by cmux's
/// main menu. This is the seam that lets VS Code (running in code-server
/// inside the embedded browser) receive Cmd+P, Cmd+Shift+P, Cmd+F, Cmd+B,
/// Cmd+D, etc.
///
/// Default behavior (empty allowlist) is unchanged. When a chord is forwarded
/// but the page does NOT consume it (e.g. Cmd+Q has no JS handler), callers
/// fall back to AppKit's standard menu dispatch so system shortcuts still work.
///
/// `@MainActor` on the function (not just the body) gives compile-time
/// guarantees that callers are on the main actor, instead of only the runtime
/// trap from `MainActor.assumeIsolated`. The function takes a plain `URL?`
/// rather than a `WKWebView` reference so tests can exercise the policy
/// without instantiating a web view.
@MainActor
func shouldPassthroughCommandEquivalentToWebContent(
    _ event: NSEvent,
    responder: NSResponder? = nil,
    url: URL?,
    defaults: UserDefaults = .standard
) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags.contains(.command) else { return false }

    if cmuxIsLikelyWebInspectorResponder(responder) {
        return false
    }

    return BrowserLinkOpenSettings.urlMatchesShortcutPassthrough(url, defaults: defaults)
}
