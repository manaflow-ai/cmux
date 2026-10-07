import CmuxMobileWire

/// One viewer's live attach to a terminal on the session host (seam for C1
/// and the app's daemon adapter).
public protocol MobileTerminalAttachment: Sendable {
    /// `channel.opened` params: generation, grid, GHOSTSNP version or nil for byte replay, title.
    var opened: TerminalOpenedParams { get }
    var events: AsyncStream<MobileTerminalEvent> { get }
    /// Keys, mouse and committed text (kind bytes) or paste (the host brackets by its mode).
    func write(_ input: TerminalInput) async
    func setViewport(_ viewport: TerminalViewport) async
    func setPresence(visible: Bool, counts: Bool) async
    func requestSnapshot(_ request: MobileSnapshotRequest) async
    /// `terminal.history`, `terminal.read_range`, `terminal.kick`: answers to
    /// send back on the channel. Throws `MobileDaemonError` when unsupported.
    func handle(_ message: ChannelMessage) async throws -> [ChannelMessage]
    func detach() async
}

extension MobileTerminalAttachment {
    public func handle(_ message: ChannelMessage) async throws -> [ChannelMessage] {
        throw MobileDaemonError(code: "proto.unsupported", message: "\(message.name) is not supported by this host")
    }
}
