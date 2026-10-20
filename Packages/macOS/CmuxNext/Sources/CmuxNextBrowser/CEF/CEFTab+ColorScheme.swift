import Foundation

extension CEFTab: BrowserColorSchemeApplying {
    public func applyColorScheme(_ scheme: BrowserColorScheme) { CEFColorScheme.apply(scheme, to: self) }
}

/// A Chromium page's `prefers-color-scheme` through DevTools media
/// emulation (`Emulation.setEmulatedMedia`). Chromium draws in its own child
/// window, so the host view's appearance does not reach the page. An empty
/// value clears the emulation (system). The call also carries the page's
/// reduced-motion emulation (`WebDevToolsToggles.emulatedMedia`).
enum CEFColorScheme {
    static func apply(_ scheme: BrowserColorScheme, to tab: CEFTab) {
        // One call carries the color scheme and Developer Tools' reduced motion, so neither clears the other.
        tab.devToolsModes.colorScheme = scheme == .system ? "" : scheme.rawValue
        guard let browserID = tab.browserID, !tab.isClosed else { return }
        let runtime = tab.runtime
        let media = tab.devToolsModes.emulatedMedia
        Task {
            _ = try? await runtime.devTools(browserID, method: media.method, params: media.params)
        }
    }
}
