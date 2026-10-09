import CmuxLink
import Foundation
@preconcurrency import Network

/// `MobileLoopbackConnector` on Network.framework: literal loopback
/// addresses only, the loopback interface required, proxies bypassed. No
/// name is resolved, so nothing but this Mac's loopback is reachable.
public struct NetworkLoopbackConnector: MobileLoopbackConnector {
    let clock: LinkClock

    public init(clock: LinkClock = .continuous) {
        self.clock = clock
    }

    public func connect(port: UInt16, timeout: Duration) async throws -> any MobileLoopbackSocket {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw MobileLoopbackConnectError.failed }
        let started = clock.now
        var last = MobileLoopbackConnectError.refused
        for host in [NWEndpoint.Host.ipv4(.loopback), .ipv6(.loopback)] {
            let remaining = timeout - (clock.now - started)
            guard remaining > .zero else { throw MobileLoopbackConnectError.timedOut }
            do {
                return try await NetworkLoopbackSocket.connect(host: host, port: nwPort, timeout: remaining, clock: clock)
            } catch let error as MobileLoopbackConnectError {
                last = error
                guard error == .refused else { throw error }
            }
        }
        throw last
    }
}
