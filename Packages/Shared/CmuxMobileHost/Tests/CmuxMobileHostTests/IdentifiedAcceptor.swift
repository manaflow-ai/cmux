import CmuxLink
import CmuxLinkTesting
import CmuxMobileHost
import Foundation

/// Gives every accepted loopback transport the identity a carrier would
/// have authenticated (B4's Noise key, B2's DTLS-bound key).
struct IdentifiedAcceptor: LinkAcceptor {
    let incoming: AsyncStream<any LinkTransport>

    init(inner: LoopbackAcceptor, identity: LinkPeerIdentity) {
        let source = inner.incoming
        let (stream, continuation) = AsyncStream.makeStream(of: (any LinkTransport).self)
        incoming = stream
        Task {
            for await transport in source {
                continuation.yield(IdentifiedTransport(inner: transport, peerIdentity: identity))
            }
            continuation.finish()
        }
    }
}

final class IdentifiedTransport: LinkTransport {
    let inner: any LinkTransport
    let peerIdentity: LinkPeerIdentity?

    init(inner: any LinkTransport, peerIdentity: LinkPeerIdentity) {
        self.inner = inner
        self.peerIdentity = peerIdentity
    }

    var path: LinkPath { get async { await inner.path } }
    var capabilities: TransportCapabilities { inner.capabilities }
    var events: AsyncStream<TransportEvent> { inner.events }
    func send(_ frame: TransportFrame) async throws { try await inner.send(frame) }
    func publishMediaTrack(_ descriptor: MediaTrackDescriptor) async throws -> MediaTrackHandle {
        try await inner.publishMediaTrack(descriptor)
    }
    func close() async { await inner.close() }
}

/// A trust store lookup by raw key (B6's `TrustedKeyLookup` in the app).
struct FixedKeyResolver: CarrierKeyResolver {
    let installs: [Data: String]
    func install(for identity: LinkPeerIdentity) async -> String? { installs[identity.publicKey] }
}
