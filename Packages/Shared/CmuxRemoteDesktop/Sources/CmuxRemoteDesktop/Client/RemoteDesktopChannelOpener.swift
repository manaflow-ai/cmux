public import CmuxMobileLink

/// Opens the `rd` channel and its datagram lane on an admitted
/// `cmux.mobile/1` session. `MobileLinkClient` is the real one; tests use a
/// harness over a loopback link.
public protocol RemoteDesktopChannelOpener: Sendable {
    func openChannel(_ request: MobileChannelRequest) async throws -> MobileOpenedChannel
    /// Throws when the path has no unreliable lane; video then stays on the channel.
    func openDatagramLane(pairedWith channel: MobileOpenedChannel) async throws -> MobileDatagramLane
}

extension MobileLinkClient: RemoteDesktopChannelOpener {
    public func openChannel(_ request: MobileChannelRequest) async throws -> MobileOpenedChannel {
        try await open(request)
    }
}
