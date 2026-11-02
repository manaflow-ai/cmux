import Foundation

/// Public tunnel metadata from this device's signed Native route; never contains its private key.
struct NativeTunnelConfiguration: Codable, Sendable {
    let id: String
    let meshId: String
    let deviceId: String
    let endpointHost: String
    let endpointPort: Int
    let serverPublicKey: String
    let interfaceAddress: String
    let meshAddress: String?
    let allowedIps: [String]
    let mtu: Int
    let persistentKeepaliveSeconds: Int
}
