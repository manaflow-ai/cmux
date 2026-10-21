import CmuxNextBrowser
import CmuxNextMacScreen
import Foundation

extension MacScreenPages {
    /// Mac Screen's refusal when `text` (typed, pasted, or the address it became,
    /// a search URL included: it is read percent-decoded too) holds an old pairing
    /// link, else nil. The one check every input surface makes: the address bar
    /// (Return and its modified opens), the New Tab page's opens and
    /// `newTab.submit` (CLI, MCP, palette). Such text is never loaded, searched or
    /// sent to an agent: the link carried a room secret.
    nonisolated static func pairingLinkRefusal(for text: String) -> String? {
        let found = BrowserURLResolver.containsPairingLink(text)
            || text.removingPercentEncoding.map(BrowserURLResolver.containsPairingLink) == true
        return found ? pairingLinkRefusal : nil
    }
}
