import Foundation
import WebKit

extension TabManager {
    /// Hashes what a browser panel's session snapshot persists about its
    /// page: the URL it restores to, and the depth of its back/forward
    /// history. Without it, a browser-only navigation leaves the autosave
    /// fingerprint unchanged, the autosave timer skips the save, and a crash
    /// or force quit restores the panel on its previous page. The URL is
    /// engine-neutral (every engine publishes its page through `currentURL`);
    /// the history depth is the WebKit list the save path reads too (a
    /// non-WebKit panel's back and forward change its URL anyway). Reads only:
    /// the full history snapshot realigns restored history, so it stays in
    /// the save path.
    static func hashBrowserSessionState(_ panel: BrowserPanel?, into hasher: inout Hasher) {
        guard let panel else {
            hasher.combine(false)
            return
        }
        hasher.combine(true)
        hasher.combine(panel.preferredURLStringForSessionSnapshot() ?? "")
        let list = panel.webView.backForwardList
        hasher.combine(list.backList.count)
        hasher.combine(list.forwardList.count)
    }
}

