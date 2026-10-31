public import WebKit

/// Why a page's web content process ended, and which process it was (cmux issue 28710): what the
/// crash notice's log line and crash marker say.
public struct PageTermination: Equatable, Sendable {
    /// WebKit's reason (`_WKProcessTerminationReason`), or ``unknown`` when this WebKit reports
    /// none (only the public `webViewWebContentProcessDidTerminate(_:)` ran) or Chromium's renderer
    /// ended.
    public enum Reason: String, Sendable {
        case memoryLimit = "memory-limit"
        case cpuLimit = "cpu-limit"
        case requestedByClient = "requested-by-client"
        case crash
        case unknown

        /// `_WKProcessTerminationReason`: ExceededMemoryLimit, ExceededCPULimit,
        /// RequestedByClient, Crash; any later value is ``unknown``.
        public init(webKit raw: Int) {
            switch raw {
            case 0: self = .memoryLimit
            case 1: self = .cpuLimit
            case 2: self = .requestedByClient
            case 3: self = .crash
            default: self = .unknown
            }
        }
    }

    public var reason: Reason
    /// The ended WebContent process; 0 when not known.
    public var pid: Int32

    public init(reason: Reason, pid: Int32 = 0) {
        self.reason = reason
        self.pid = pid
    }

    public static let unknown = PageTermination(reason: .unknown)

    /// This termination, with `fallback` as its pid when it has none (WebKit may forget the pid
    /// of a process that already ended; the host remembers the last one it saw).
    public func withPid(fallback: Int32) -> PageTermination {
        pid != 0 ? self : PageTermination(reason: reason, pid: fallback)
    }

    /// The pid of `webView`'s web content process (`_webProcessIdentifier`, WebKit SPI); 0 before
    /// the first load, after the process ended, or on a WebKit without the SPI.
    @MainActor
    public static func webContentPid(of webView: WKWebView) -> Int32 {
        // crash-allow: WebKit private selector, used only after responds(to:) confirms it exists (no unknown-selector exception).
        let selector = NSSelectorFromString("_webProcessIdentifier")
        guard webView.responds(to: selector),
              // crash-allow: KVC read of the WebKit private key above, only after responds(to:) confirmed it.
              let pid = (webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0 else { return 0 }
        return pid
    }
}
