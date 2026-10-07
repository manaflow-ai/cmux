import Foundation

/// The one seam stream features use (a3-link.md). `LinkSession` is the
/// implementation; features hold `any CmuxLink` and never import a carrier.
public protocol CmuxLink: AnyObject, Sendable {
    var state: LinkState { get async }
    /// Every state change, starting with the current state.
    func states() async -> AsyncStream<LinkState>
    /// Path and RTT changes while connected, starting with the current badge.
    func pathBadges() async -> AsyncStream<PathBadge>
    /// Dialer: starts connecting. No effect after the first call.
    func connect() async
    /// Opens a bidirectional channel. With a saved cursor the peer replays
    /// what it still retains or reports a gap.
    func openChannel(_ descriptor: ChannelDescriptor, resumeFrom cursor: StreamCursor?) async throws -> LinkChannel
    /// Channels the peer opened.
    func incomingChannels() async -> AsyncStream<LinkChannel>
    /// Media tracks the peer published.
    func incomingMediaTracks() async -> AsyncStream<MediaTrackHandle>
    func publishMediaTrack(_ descriptor: MediaTrackDescriptor) async throws -> MediaTrackHandle
    /// Feed from the platform path monitor: retries now and probes better paths.
    func networkDidChange() async
    func close() async
}

extension CmuxLink {
    public func openChannel(_ descriptor: ChannelDescriptor) async throws -> LinkChannel {
        try await openChannel(descriptor, resumeFrom: nil)
    }
}
