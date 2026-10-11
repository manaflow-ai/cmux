import Foundation
import Testing
@testable import CmuxMobileCloud

@Suite struct WireGuardQuickConfigTests {
    private let privateKey = WireGuardKeyPair().privateKey

    @Test func completesServerConfigWithPrivateKeyAndKeepalive() throws {
        let config = try WireGuardQuickConfig(completing: Fixtures.serverConfig, privateKey: privateKey)
        let lines = config.text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(lines.contains("PrivateKey = \(privateKey)"))
        #expect(lines.filter { $0.lowercased().hasPrefix("privatekey") }.count == 1)
        #expect(lines.contains("PersistentKeepalive = 25"))
        #expect(lines.contains("MTU = 1200"))
        #expect(lines.contains("Address = 100.64.0.7/32"))
        #expect(lines.contains("Address = fd7a:7570:6c6b::7/128"))
        #expect(lines.contains("AllowedIPs = 10.0.0.0/8, fd00::/8"))
        #expect(lines.contains("Endpoint = [2600:1f18::1]:51820"))
        let peerIndex = try #require(lines.firstIndex(of: "[Peer]"))
        let keepaliveIndex = try #require(lines.firstIndex(of: "PersistentKeepalive = 25"))
        #expect(keepaliveIndex > peerIndex)
    }

    @Test func insertsPrivateKeyWhenServerOmitsTheLine() throws {
        let server = "[Interface]\nAddress = 100.64.0.7/32\n\n[Peer]\nPublicKey = spk\nAllowedIPs = 10.0.0.0/8\nEndpoint = h:1\nPersistentKeepalive = 15\n"
        let config = try WireGuardQuickConfig(completing: server, privateKey: privateKey)
        let lines = config.text.split(separator: "\n").map(String.init)
        #expect(lines[0] == "[Interface]")
        #expect(lines[1] == "PrivateKey = \(privateKey)")
        #expect(lines.filter { $0.hasPrefix("PersistentKeepalive") } == ["PersistentKeepalive = 25"])
    }

    @Test func rejectsConfigsWithoutSections() {
        #expect(throws: WireGuardQuickConfig.Failure.missingInterfaceSection) {
            try WireGuardQuickConfig(completing: "PrivateKey =\n", privateKey: privateKey)
        }
        #expect(throws: WireGuardQuickConfig.Failure.missingPeerSection) {
            try WireGuardQuickConfig(completing: "[Interface]\nPrivateKey =\n", privateKey: privateKey)
        }
    }

    @Test func buildsFromFieldsWhenServerSendsNoText() throws {
        var enrollment = Fixtures.enrollment
        enrollment.clientConfig = ""
        let config = try WireGuardQuickConfig.make(enrollment: enrollment, privateKey: privateKey)
        let expected = """
        [Interface]
        PrivateKey = \(privateKey)
        Address = 100.64.0.7/32
        Address = fd7a:7570:6c6b::7/128
        MTU = 1200

        [Peer]
        PublicKey = \(enrollment.serverPublicKey)
        AllowedIPs = 10.0.0.0/8, fd00::/8
        Endpoint = [2600:1f18::1]:51820
        PersistentKeepalive = 25

        """
        #expect(config.text == expected)
    }

    @Test func makePrefersServerText() throws {
        let config = try WireGuardQuickConfig.make(enrollment: Fixtures.enrollment, privateKey: privateKey)
        #expect(config.text.contains("Address = fd7a:7570:6c6b::7/128"))
        #expect(config.text.contains("PrivateKey = \(privateKey)"))
    }
}
