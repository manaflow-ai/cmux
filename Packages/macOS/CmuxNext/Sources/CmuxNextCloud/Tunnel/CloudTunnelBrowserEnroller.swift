import CryptoKit
public import Foundation

/// Enrolls the opt-in Cloud Tunnel's `browser` peer: a fresh Curve25519 key per enrollment,
/// `POST /api/vm/tunnel` with this Mac's device id (the hub's, so cmux.com shows one Mac), and
/// the server's config completed with the key and every network route. The key exists only in
/// the returned text, which the caller hands to NetworkExtension.
public struct CloudTunnelBrowserEnroller: Sendable {
    private let api: CloudAPIClient
    private let paths: CloudPaths
    private let deviceName: String

    /// - Parameters:
    ///   - api: The signed-in Cloud API client.
    ///   - paths: Where this Mac's device id lives (shared with the userspace hub).
    ///   - deviceName: The Mac's name as cmux.com lists it.
    public init(api: CloudAPIClient, paths: CloudPaths, deviceName: String) {
        self.api = api
        self.paths = paths
        self.deviceName = deviceName
    }

    /// Enrolls a fresh peer and returns its completed wg-quick config.
    public func enrollBrowserPeer() async throws -> String {
        let key = Curve25519.KeyAgreement.PrivateKey()
        var request = CloudTunnelEnrollment.Request(
            clientPublicKey: key.publicKey.rawRepresentation.base64EncodedString(),
            deviceID: try paths.loadOrCreateDeviceID(),
            deviceName: deviceName,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: Self.architecture,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "next"
        )
        request.tunnelPurpose = "browser"
        let enrollment = try await api.enrollTunnel(request)
        return WireGuardConfig.shared.completed(enrollment, privateKey: key.rawRepresentation.base64EncodedString())
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }
}
