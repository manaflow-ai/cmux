import CmuxTerminalCore
import Foundation

/// The app-side conformance injected into ``TerminalLinkRouter``: terminal
/// links validate hosts and resolve bare domains through the same browser
/// rules the embedded browser uses.
struct TerminalBrowserHostNormalizer: BrowserHostNormalizing {
    func normalizedHost(_ rawHost: String) -> String? {
        BrowserInsecureHTTPSettings.normalizeHost(rawHost)
    }

    func navigableWebURL(_ input: String) -> URL? {
        resolveBrowserNavigableURL(input)
    }

    func resolveOpenURLTarget(_ rawValue: String) -> TerminalOpenURLTarget? {
        TerminalLinkRouter(hostNormalizer: self).resolveOpenURLTarget(rawValue)
    }
}
