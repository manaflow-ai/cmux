/// A media track a feature renders (dialer) or feeds (publisher). Features
/// never see the carrier type behind it.
public final class MediaTrackHandle: Sendable, Identifiable {
    public let descriptor: MediaTrackDescriptor
    private let backing: any MediaTrackBacking

    public init(descriptor: MediaTrackDescriptor, backing: any MediaTrackBacking) {
        self.descriptor = descriptor
        self.backing = backing
    }

    public var id: String { descriptor.id }

    public func states() async -> AsyncStream<MediaTrackState> { await backing.states() }
    public func attach(_ sink: any MediaFrameSink) async { await backing.attach(sink) }
    public func detach(_ sink: any MediaFrameSink) async { await backing.detach(sink) }
    public func push(_ frame: MediaFrame) async { await backing.push(frame) }
    public func stop() async { await backing.stop() }
}
