/// Where a terminal view attaches: a stream on its machine's connection, or a
/// connection of its own.
///
/// A machine's `DaemonService` gives the route of its views
/// (`DaemonService.terminalAttachRoute`); ``TerminalAttachment/attach(route:target:size:claimGeometry:snapshotVersion:localHistory:images:device:)``
/// takes the stream when ``streams`` gives a carrier, else a connection to ``endpoint``.
///
/// ```swift
/// // A test view that never reaches a daemon.
/// let route = TerminalAttachRoute(streams: nil, endpoint: { throw CancellationError() })
/// ```
public struct TerminalAttachRoute: Sendable {
    /// The machine's connection as a stream carrier for a device; nil, or a
    /// carrier provider that returns nil, when views open their own connections.
    public let streams: (@Sendable (TerminalSizingDevice) async throws -> TerminalStreamCarrier?)?
    /// The daemon socket for a connection of the view's own.
    public let endpoint: @Sendable () async throws -> DaemonEndpoint

    /// Makes a route.
    ///
    /// - Parameters:
    ///   - streams: The machine's stream carrier for a device, or nil to always
    ///     open a connection of the view's own.
    ///   - endpoint: The daemon socket for a connection of the view's own.
    public init(streams: (@Sendable (TerminalSizingDevice) async throws -> TerminalStreamCarrier?)?,
                endpoint: @escaping @Sendable () async throws -> DaemonEndpoint) {
        self.streams = streams
        self.endpoint = endpoint
    }
}
