/// Hands out the admitted session to a host (lane D1/B6 owns dialing and
/// device proof). Throws when the host is unreachable or not paired.
public protocol MobileSessionLinkProvider: Sendable {
    func session(toHost hostID: String) async throws -> any MobileSessionLink
}
