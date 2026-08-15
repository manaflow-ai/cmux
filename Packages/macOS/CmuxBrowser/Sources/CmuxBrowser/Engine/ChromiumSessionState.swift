/// Lifecycle state of one managed Chromium child and page connection.
public enum ChromiumSessionState: Equatable, Sendable {
    /// No child process is active.
    case stopped
    /// The runtime is installing or the child/CDP connection is starting.
    case starting
    /// The child and page-scoped CDP connection are ready.
    ///
    /// The endpoint is `nil` for the private pipe transport and non-`nil`
    /// only when the user explicitly enabled a loopback listener.
    case running(BrowserCDPEndpoint?)
    /// The child or renderer exited unexpectedly with the supplied status.
    case crashed(Int32)
    /// Startup failed without taking down the host application.
    case failed(String)
}
