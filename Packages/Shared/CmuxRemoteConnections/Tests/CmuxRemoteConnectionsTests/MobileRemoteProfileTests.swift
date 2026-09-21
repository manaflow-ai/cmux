import Foundation
import Testing
@testable import CmuxRemoteConnections

@Suite struct MobileRemoteProfileTests {
    let profileID = UUID()
    @Test(arguments: ["server.example", "100.64.0.5", "fd7a:115c:a1e0::1", "host.tailnet.ts.net"])
    func acceptsReachableAddressShapesWithoutAVPNVendorGate(host: String) throws {
        let profile = try MobileRemoteProfile(id: profileID, host: host, username: "alice")
        #expect(profile.port == 22)
        #expect(profile.hostKeyPolicy == .ask)
        #expect(profile.credentialID == nil)
        let restored = try JSONDecoder().decode(
            MobileRemoteProfile.self, from: JSONEncoder().encode(profile)
        )
        #expect(restored == profile)
    }

    @Test(arguments: ["ssh://example.com", "alice@example.com", "example.com\ncommand", "a/b", "a b"])
    func rejectsDestinationControlSyntax(host: String) {
        #expect(throws: MobileRemoteProfileError.invalidHost) {
            try MobileRemoteProfile(id: profileID, host: host, username: "alice")
        }
    }

    @Test func decoderCannotBypassPortOrJumpValidation() throws {
        let valid = try MobileRemoteProfile(id: profileID, host: "example.com", username: "alice")
        let encoded = try JSONEncoder().encode(valid)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["port"] = 0
        let invalidPort = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: MobileRemoteProfileError.invalidPort(0)) {
            try JSONDecoder().decode(MobileRemoteProfile.self, from: invalidPort)
        }
        object["port"] = 22
        object["jumpHostProfileID"] = profileID.uuidString
        let invalidJump = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: MobileRemoteProfileError.selfReferentialJumpHost) {
            try JSONDecoder().decode(MobileRemoteProfile.self, from: invalidJump)
        }
    }

    @Test(arguments: ["", "1INVALID", "INVALID-KEY", "BAD=KEY"])
    func rejectsInvalidEnvironmentNames(key: String) {
        #expect(throws: MobileRemoteProfileError.invalidEnvironmentKey) {
            try MobileRemoteProfile(
                id: profileID, host: "example.com", username: "alice",
                environment: [key: "value"]
            )
        }
    }

    @Test(arguments: ["main", "dev-1", "a_b.c"])
    func acceptsSafeCmuxSessionNames(sessionName: String) throws {
        let profile = try MobileRemoteProfile(
            id: profileID, host: "example.com", username: "alice",
            sessionBackend: .cmuxTUI, sessionName: sessionName
        )
        #expect(profile.sessionName == sessionName)
    }

    @Test(arguments: ["main; rm -rf /", "name with spaces", "name'quote", String(repeating: "x", count: 129)])
    func rejectsCmuxSessionShellSyntax(sessionName: String) {
        #expect(throws: MobileRemoteProfileError.invalidSessionName) {
            try MobileRemoteProfile(
                id: profileID, host: "example.com", username: "alice",
                sessionBackend: .cmuxTUI, sessionName: sessionName
            )
        }
    }

    @Test func environmentValuesRemainDataAndCannotContainNUL() throws {
        let data = "line one\nline two; $(never executed)"
        let profile = try MobileRemoteProfile(
            id: profileID, host: "example.com", username: "alice",
            environment: ["VALUE": data]
        )
        #expect(profile.environment["VALUE"] == data)
        #expect(throws: MobileRemoteProfileError.invalidEnvironmentValue) {
            try MobileRemoteProfile(
                id: profileID, host: "example.com", username: "alice",
                environment: ["VALUE": "hello\0world"]
            )
        }
    }

    @Test func roundTripsMoshETAndNativeCmuxSettings() throws {
        let profile = try MobileRemoteProfile(
            id: profileID, host: "example.com", username: "alice",
            sessionBackend: .cmuxTUI, sessionName: "work",
            moshServerPath: "/opt/bin/mosh-server", moshUDPPortRange: 60_000...60_010,
            eternalTerminalPort: 2022
        )
        let restored = try JSONDecoder().decode(
            MobileRemoteProfile.self, from: JSONEncoder().encode(profile)
        )
        #expect(restored == profile)
    }
}
