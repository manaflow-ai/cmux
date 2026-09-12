public import Foundation

/// A Chromium pane's externally advertised loopback CDP endpoint.
public struct BrowserCDPEndpoint: Codable, Equatable, Sendable {
    /// The loopback TCP port bound by the managed Chromium child.
    public let port: Int

    /// The page-scoped WebSocket used by cmux's internal automation adapter.
    public let websocketURL: URL?

    /// Creates endpoint metadata for an already-bound child process.
    ///
    /// - Parameters:
    ///   - port: The child process's loopback TCP port.
    ///   - websocketURL: Its page-scoped CDP WebSocket, when discovered.
    public init(port: Int, websocketURL: URL? = nil) {
        self.port = port
        self.websocketURL = websocketURL
    }

    /// The HTTP origin accepted by Playwright's `connectOverCDP` API.
    public var connectOverCDPURL: URL? {
        guard let validatedPort = ChromiumRemoteDebuggingPort(rawValue: port),
              validatedPort.isExternallyAttachable else { return nil }
        return URL(string: "http://127.0.0.1:\(port)")
    }
}
