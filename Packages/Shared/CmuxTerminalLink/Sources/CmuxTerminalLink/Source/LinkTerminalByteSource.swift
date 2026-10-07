public import CmuxLink
public import CmuxMobileLink
public import CmuxTerminalRenderCore
public import CmuxTerminalStream
public import Foundation

/// `TerminalByteSource` for one terminal of a cmux session host over a
/// `cmux.mobile/1` terminal channel (`.host` authority; c1-terminal-rpc.md).
///
/// `open` attaches (READY first, then live bytes), `send` writes ordered
/// `TerminalInput` records at link priority `input`, `viewportChanged` sends
/// presence and viewport only when they change, and floods, link gaps and
/// prediction mismatches all resolve to a fresh READY.
public final class LinkTerminalByteSource: TerminalByteSource {
    public let terminalID: String
    public let options: TerminalLinkOptions
    private let connection: LinkTerminalConnection

    /// - Parameters:
    ///   - client: the phone's session with the Mac that owns `terminal`.
    ///   - describe: the user-facing text of a stream end (localized by the app).
    public init(terminal: String, client: MobileLinkClient, options: TerminalLinkOptions = TerminalLinkOptions(),
                clock: LinkClock = .continuous,
                describe: @escaping @Sendable (TerminalLinkFailure) -> String = { $0.defaultText }) {
        terminalID = terminal
        self.options = options
        connection = LinkTerminalConnection(terminal: terminal, client: client, options: options, clock: clock,
                                            describe: describe)
    }

    public var authority: TerminalAuthority { .host }

    public func open(_ viewport: TerminalViewport) async throws -> AsyncStream<TerminalSourceEvent> {
        await connection.open(viewport)
    }

    public func send(_ input: Data) async throws {
        try await connection.send(input)
    }

    public func viewportChanged(_ viewport: TerminalViewport) async {
        await connection.viewportChanged(viewport)
    }

    public func requestSnapshot(_ request: SnapshotRequest) async throws {
        await connection.requestSnapshot(request)
    }

    public func close() async {
        await connection.close()
    }

    /// Older scrollback before `offset` (nil: before the restored READY),
    /// answered with `snapshot_history` frames on the stream.
    public func requestHistory(before offset: UInt64?, maxBytes: Int) async {
        await connection.requestHistory(before: offset, maxBytes: maxBytes)
    }

    /// Latency and catch-up numbers, newest first.
    public func telemetry() async -> AsyncStream<TerminalLatencyReport> {
        await connection.telemetry()
    }

    /// Why the last stream ended, if it did.
    public func lastFailure() async -> TerminalLinkFailure? {
        await connection.lastFailure
    }
}
