import CmuxLink
import Foundation

/// The two ends of a benchmark channel.
///
/// A local loopback fixture returns both handles. A split fixture only has the
/// dialer's handle; the Mac-side serve process owns the other handle and runs
/// the echo/source service. Keeping the optional remote handle here lets the
/// workload code stay identical in both modes.
public struct BenchChannelPair: Sendable {
    public let local: LinkChannel
    public let remote: LinkChannel?

    public init(local: LinkChannel, remote: LinkChannel? = nil) {
        self.local = local
        self.remote = remote
    }
}

/// A connected benchmark peer. This is deliberately smaller than
/// ``ConformanceHarness``: an iOS split client cannot inject faults into a
/// Mac process, but it can run the same channel workloads over a real carrier.
public protocol BenchFixtureProtocol: Sendable {
    var dialer: LinkSession { get }
    var connectToLive: Duration { get }
    func openPair(_ descriptor: ChannelDescriptor) async throws -> BenchChannelPair
    func shutdown() async
}
