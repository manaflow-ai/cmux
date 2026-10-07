/// Decides from a path snapshot whether a direct endpoint can be reached
/// (b4-direct.md section 5). Pure: the monitor feeds it snapshots.
public struct DirectRouteEvaluator: Sendable {
    public init() {}

    public func status(for target: DirectEndpoint.Target, on snapshot: DirectPathSnapshot) -> DirectRouteStatus {
        switch target {
        case let .address(address, _):
            status(for: address.addressClass, on: snapshot)
        case .service:
            snapshot.hasLocalNetwork ? .available : .unavailable(snapshot.isSatisfied ? .noLocalNetwork : .offline)
        }
    }

    public func status(for addressClass: DirectAddressClass, on snapshot: DirectPathSnapshot) -> DirectRouteStatus {
        if addressClass == .loopback { return .available }
        guard snapshot.isSatisfied else { return .unavailable(.offline) }
        switch addressClass {
        case .loopback, .publicNetwork:
            return .available
        case .tailscale:
            return snapshot.hasTunnel ? .available : .unavailable(.noTunnel)
        case .privateNetwork:
            return snapshot.hasLocalNetwork || snapshot.hasTunnel ? .available : .unavailable(.noLocalNetwork)
        }
    }
}
