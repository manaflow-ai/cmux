/// Where a transport's ICE servers come from: B1's TURN minting in
/// production (`ControlPlaneSignaling`), a fixed set in tests.
public protocol ICEServerProvider: Sendable {
    func iceConfiguration(for hostID: String) async throws -> ICEConfiguration
}
