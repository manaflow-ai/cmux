public import Foundation

/// A `serve-web` process that is ready: it printed its Web UI URL.
public struct VSCodeServeWebStarted: Sendable {
    /// The running process.
    public let handle: any VSCodeServeWebProcessHandle
    /// The Web UI URL the server printed, with its connection token.
    public let url: URL

    /// Creates a started server.
    /// - Parameters:
    ///   - handle: The running process.
    ///   - url: Its Web UI URL.
    public init(handle: any VSCodeServeWebProcessHandle, url: URL) {
        self.handle = handle
        self.url = url
    }
}
