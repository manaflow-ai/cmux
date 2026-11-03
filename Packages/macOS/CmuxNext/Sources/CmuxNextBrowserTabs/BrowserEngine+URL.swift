public import CmuxNextBrowser
public import CmuxNextDaemon
public import Foundation

extension CmuxNextDaemon.BrowserEngine {
    /// The engine a URL needs: Chromium for its internal pages
    /// (ChromiumInternalURL), else nil (the default engine decides).
    public nonisolated static func engine(for url: URL?) -> String? {
        guard let url, ChromiumInternalURL.needsChromium(url) else { return nil }
        return CmuxNextDaemon.BrowserEngine.cef.rawValue
    }
}
