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
