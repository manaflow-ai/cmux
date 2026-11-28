import Foundation

extension CEFTab: BrowserColorSchemeApplying {
    public func applyColorScheme(_ scheme: BrowserColorScheme) { CEFColorScheme.apply(scheme, to: self) }
}

/// A Chromium page's `prefers-color-scheme` through DevTools media
/// emulation (`Emulation.setEmulatedMedia`). Chromium draws in its own child
/// window, so the host view's appearance does not reach the page. An empty
/// value clears the emulation (system).
enum CEFColorScheme {
    static func apply(_ scheme: BrowserColorScheme, to tab: CEFTab) {
        guard let browserID = tab.browserID, !tab.isClosed else { return }
        let runtime = tab.runtime
        Task {
            _ = try? await runtime.devTools(browserID, method: "Emulation.setEmulatedMedia", params: emulatedMediaParams(scheme))
        }
    }

    nonisolated static func emulatedMediaParams(_ scheme: BrowserColorScheme) -> [String: Any] {
        let value = scheme == .system ? "" : scheme.rawValue
        return ["features": [["name": "prefers-color-scheme", "value": value]]]
    }
}
