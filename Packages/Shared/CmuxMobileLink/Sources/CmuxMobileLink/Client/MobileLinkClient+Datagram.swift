import CmuxLink
import CmuxMobileWire

/// Datagram lanes (c2-browser-stream.md section 2): an unreliable link
/// channel named `cmux.mobile/datagram/<id>`, paired with an opened A0
/// channel of the same session generation. It carries no `channel.open`;
/// the Mac binds it by name. Throws when the session moved on or the path
/// cannot carry it (callers fall back to the reliable channel).
extension MobileLinkClient {
    public func openDatagramLane(for opened: MobileOpenedChannel,
                                 priority: ChannelPriority = .media) async throws -> MobileDatagramLane {
        guard let link = linkSession(generation: opened.generation) else { throw MobileLinkClientError.linkLost }
        let channel = try await link.openChannel(
            ChannelDescriptor(stream: DatagramLaneName(channel: opened.channel.id).stream, reliability: .unreliableUnordered,
                              priority: priority),
            resumeFrom: nil)
        return MobileDatagramLane(channel: opened.channel.id, link: channel)
    }
}
