import CmuxLinkDirect
import CmuxLinkWebRTC
import CmuxMobileConnect
import CmuxMobileConnectHost
import CmuxMobileLink
import CmuxMobileWire
import CmuxPairing
import CryptoKit
import Foundation

/// One account with a phone and a Mac, both with published `direct` certs
/// signed by their install keys, in a trust store mirror both ends read.
struct ConnectFixture: Sendable {
    static let environment = "test"
    static let user = "user_a1"
    static let hostID = "host_a1"
    static let phoneInstall = "inst_p1"
    static let macInstall = "inst_m1"

    let phoneKey = P256.Signing.PrivateKey()
    let macKey = P256.Signing.PrivateKey()
    let phoneDirect = DirectIdentity()
    let macDirect = DirectIdentity()
    let mirror: TrustStoreMirror

    init() async throws {
        let now = Date()
        let phoneCert = try await LinkCertificateIssuer(environment: Self.environment, user: Self.user, install: Self.phoneInstall,
                                                        signer: FixtureSigner(key: phoneKey))
            .issue(purpose: .direct, key: phoneDirect.publicKey.rawRepresentation, now: now)
        let macCert = try await LinkCertificateIssuer(environment: Self.environment, user: Self.user, install: Self.macInstall,
                                                      signer: FixtureSigner(key: macKey))
            .issue(purpose: .direct, key: macDirect.publicKey.rawRepresentation, now: now)
        let state = TrustStoreState(devices: [
            Self.phoneInstall: TrustDevice(install: Self.phoneInstall, kind: "ios", name: "iPhone", platform: "ios",
                                           publicKey: InstallPublicKey(phoneKey.publicKey),
                                           certs: TrustDeviceCerts(direct: phoneCert), updatedAt: 1),
            Self.macInstall: TrustDevice(install: Self.macInstall, kind: "mac", name: "Studio", platform: "macos",
                                         publicKey: InstallPublicKey(macKey.publicKey), host: Self.hostID,
                                         certs: TrustDeviceCerts(direct: macCert), updatedAt: 1),
        ])
        mirror = TrustStoreMirror(state: state)
    }

    var lookup: TrustStoreKeyLookup {
        TrustStoreKeyLookup(mirror: mirror, environment: Self.environment, user: Self.user)
    }

    var trust: MobileHostTrust {
        MobileHostTrust(mirror: mirror, environment: Self.environment, accountUserID: Self.user)
    }

    func phoneCredentials() throws -> MobileDeviceCredentials {
        MobileDeviceCredentials(
            signer: FixtureDeviceSigner(install: Self.phoneInstall, keyID: MobileDeviceCredentials.installKeyID, key: phoneKey),
            client: HelloClient(install: Self.phoneInstall, platform: "ios", appVersion: "1.0"),
            direct: phoneDirect,
            webrtc: try SoftwareWebRTCIdentity(privateKeyRepresentation: phoneKey.rawRepresentation))
    }

    func hostCredentials() throws -> MobileHostCredentials {
        MobileHostCredentials(hostID: Self.hostID, accountUserID: Self.user, direct: macDirect,
                              webrtc: try SoftwareWebRTCIdentity(privateKeyRepresentation: macKey.rawRepresentation))
    }

    /// The Mac's route as the phone's trust store builds it.
    func route(targets: [DirectEndpoint.Target]) async throws -> MobileHostRoute {
        guard let key = await lookup.hostKey(for: Self.hostID), let route = MobileHostRoute(trusted: key, targets: targets) else {
            throw FixtureError.noRoute
        }
        return route
    }
}

enum FixtureError: Error { case noRoute, noClient }

struct FixtureSigner: LinkKeySigning {
    let key: P256.Signing.PrivateKey
    func sign(_ message: Data) async throws -> Data { try key.signature(for: message).rawRepresentation }
}

struct FixtureDeviceSigner: MobileDeviceSigner {
    let install: String
    let keyID: String
    let key: P256.Signing.PrivateKey
    func sign(_ message: Data) throws -> Data { try key.signature(for: message).rawRepresentation }
}
