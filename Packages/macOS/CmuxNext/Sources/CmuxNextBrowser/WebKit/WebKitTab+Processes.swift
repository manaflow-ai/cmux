import CmuxNextSignposts
import Foundation
import WebKit

extension WebKitTab: BrowserProcessReporting {
    /// The WebContent process of this web view (`_webProcessIdentifier`,
    /// WebKit SPI; 0 before the first load or after the process ended).
    public var contentProcesses: BrowserContentProcesses {
        let selector = NSSelectorFromString("_webProcessIdentifier")
        guard webView.responds(to: selector),
              let pid = (webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0 else { return .none }
        return .pids([pid])
    }
}

extension WebKitTab {
    /// The main frame committed: the process it committed in is the one a later content end names
    /// (``RendererStability/webKitContentCommitted(in:)``).
    func contentCommitted() {
        guard case let .pids(pids) = contentProcesses, let pid = pids.first else { return }
        committedContentProcess = pid
        engine?.rendererStability.webKitContentCommitted(in: pid)
    }

    /// The tab's content process ended: one stability event, its process named so the other pages it served add no
    /// process end.
    func contentProcessEnded() {
        engine?.rendererStability.webKitContentEnded(on: .browserTab, process: committedContentProcess)
        committedContentProcess = nil
    }
}
