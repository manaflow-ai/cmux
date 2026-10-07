import CmuxInstallAuthCore
import CmuxLinkWebRTC
import CmuxPairing
import CryptoKit
import Foundation
@testable import CmuxNextMobileConnect
import Testing

@Suite("Mac install account")
struct InstallHostAccountTests {
    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("d1b-account-\(UUID().uuidString)", isDirectory: true)
    }

    private func account(_ api: FakeAPI, _ dir: URL, name: String = "Studio") -> InstallHostAccount {
        InstallHostAccount(apiBaseURL: URL(string: "https://api.example")!, stackUser: "stack_1",
                           sessionToken: { "stack-session" }, deviceName: name, clientVersion: "1.0",
                           key: MacInstallKey(storage: .file(dir.appendingPathComponent("install-key")), allowsEnclave: false),
                           records: MacInstallRecordStore(file: dir.appendingPathComponent("install-records.json")),
                           transport: api, macName: { name }, isCurrent: { true })
    }

    @Test func registersAMacInstallEnrollsTheHostAndNamesThePrincipal() async throws {
        let api = FakeAPI(), dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let principal = try await account(api, dir).principal()
        #expect(principal == MobileLinkHostPrincipal(hostID: "host_m1", accountUserID: "user_1", install: "inst_mac1",
                                                     environment: "staging", apiBaseURL: URL(string: "https://api.example")!))
        let registration = try #require(await api.registrations.first)
        #expect(registration == ["kind": "mac", "platform": "macos", "op_classes": "default"])
        let enrollment = try #require(await api.enrollments.first)
        #expect(enrollment.name == "Studio")
        #expect(enrollment.bearer?.hasPrefix("e30.") == true)
    }

    @Test func aRelaunchReusesTheRecordAndTheKeyAndEnrollsTheSameHost() async throws {
        let api = FakeAPI(), dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await account(api, dir).principal()
        let again = try await account(api, dir, name: "Studio").principal()
        #expect(again.hostID == "host_m1")
        #expect(await api.registrations.count == 1)
        let keys = await api.enrollments.map(\.key)
        #expect(keys.count == 2 && keys[0] == keys[1])
    }

    @Test func theSignersAreTheRegisteredInstallKey() async throws {
        let api = FakeAPI(), dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let made = account(api, dir)
        let principal = try await made.principal()
        let registered = try #require(await api.installKey)
        let identity = try #require(made.webrtcIdentity)
        #expect(identity.publicKey == WebRTCPublicKey(x963Representation: registered.x963Representation))
        let signer = try #require(made.installSigner)
        let issuer = LinkCertificateIssuer(environment: principal.environment, user: principal.accountUserID,
                                           install: principal.install, signer: signer)
        let cert = try await issuer.issue(purpose: .direct, key: Data(repeating: 7, count: 32))
        try cert.verify(installKey: registered, environment: "staging",
                        now: Int64(Date().timeIntervalSince1970 * 1000))
    }
}
