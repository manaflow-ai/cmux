import CmuxTerminalCore
import Foundation

/// App-side host policy injected into ``TerminalLinkRouter``.
nonisolated struct TerminalBrowserHostNormalizer: BrowserHostNormalizing, Sendable {
    func normalizedHost(_ rawHost: String) -> String? {
        BrowserInsecureHTTPSettings.normalizeHost(rawHost)
    }

    func navigableWebURL(_ input: String) -> URL? {
        resolveBrowserNavigableURL(input)
    }
}
