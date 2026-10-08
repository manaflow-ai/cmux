import CmuxLink
import CmuxLinkDirect
import Foundation

/// The iOS/client half of F2. It opens a real `LinkSession` to a Mac
/// `BenchSplitServer`; the server owns the accepted session and services the
/// channel descriptors. A new instance is created for every workload sample.
public final class BenchSplitFixture: BenchFixtureProtocol, Sendable {
    public let dialer: LinkSession
    public let connectToLive: Duration

    private init(dialer: LinkSession, connectToLive: Duration) {
        self.dialer = dialer
        self.connectToLive = connectToLive
    }

    public static func connect(
        descriptor: BenchServeDescriptor,
        deviceIdentity: DirectIdentity,
        configuration: LinkConfiguration = LinkConfiguration(handshakeTimeout: .seconds(10), maxConnectAttempts: 4, degradedRTT: nil)
    ) async throws -> BenchSplitFixture {
        try descriptor.validate()
        guard descriptor.directEndpoint != nil else {
            throw BenchSplitError.invalidDescriptor("direct endpoint")
        }
        let carrier = DirectCarrier(identity: deviceIdentity, resolver: DirectHintsResolver())
        let dialer = LinkSession(
            peer: descriptor.peer,
            selector: PathSelector(carriers: [carrier], policy: PathPolicy(upgradeRetry: nil)),
            configuration: configuration
        )
        let states = await dialer.states()
        let clock = ContinuousClock()
        let start = clock.now
        await dialer.connect()
        guard let live = try await TimeLimit(configuration.handshakeTimeout).run({
            for await state in states {
                if state.isLive { return true }
                if state.isClosed { return false }
            }
            return false
        }), live else {
            await dialer.close()
            throw BenchSplitError.server("dialer did not reach a live path")
        }
        return BenchSplitFixture(dialer: dialer, connectToLive: clock.now - start)
    }

    public func openPair(_ descriptor: ChannelDescriptor) async throws -> BenchChannelPair {
        BenchChannelPair(local: try await dialer.openChannel(descriptor))
    }

    public func shutdown() async {
        await dialer.close()
    }
}
