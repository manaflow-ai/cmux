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
        return try await connect(descriptor: descriptor, carriers: [carrier], configuration: configuration)
    }

    /// Connects a split fixture through one or more carriers assembled by the
    /// caller. B5's V1/V2 signaling adapters use this path so the benchmark
    /// service remains transport-agnostic and the same workloads can run on a
    /// real control-plane channel or an in-memory test channel.
    public static func connect(
        descriptor: BenchServeDescriptor,
        carriers: [any LinkCarrier],
        configuration: LinkConfiguration = LinkConfiguration(handshakeTimeout: .seconds(10), maxConnectAttempts: 4, degradedRTT: nil)
    ) async throws -> BenchSplitFixture {
        try descriptor.validate()
        guard !carriers.isEmpty else { throw BenchSplitError.invalidDescriptor("carriers") }
        let dialer = LinkSession(
            peer: descriptor.peer,
            selector: PathSelector(carriers: carriers, policy: PathPolicy(upgradeRetry: nil)),
            configuration: configuration
        )
        let states = await dialer.states()
        let clock = ContinuousClock()
        let start = clock.now
        do {
            await dialer.connect()
            guard let live = try await TimeLimit(configuration.handshakeTimeout).run({
                for await state in states {
                    if state.isLive { return true }
                    if state.isClosed { return false }
                }
                return false
            }), live else {
                throw BenchSplitError.server("dialer did not reach a live path")
            }
            return BenchSplitFixture(dialer: dialer, connectToLive: clock.now - start)
        } catch {
            await dialer.close()
            throw error
        }
    }

    public func openPair(_ descriptor: ChannelDescriptor) async throws -> BenchChannelPair {
        BenchChannelPair(local: try await dialer.openChannel(descriptor))
    }

    public func shutdown() async {
        await dialer.close()
    }
}
