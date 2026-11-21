import Foundation
import Testing
@testable import CMUXMobileCore

/// Behavior coverage for the current Cloud daemon endpoint contract.
@Suite struct CmxCloudAttachTests {
    private func response() -> [String: Any] {
        [
            "transport": "cmux-remote",
            "route": "ws://10.0.0.2:7777/v1/link",
            "token": "lease-ledger-secret",
            "expiresAtUnix": 1_900_000_000,
            "session": "cloud",
            "trustedCarrier": true,
        ]
    }

    private func decode(_ object: [String: Any]) throws -> CmxCloudAttachEndpoint {
        try CmxCloudAttach().decode(JSONSerialization.data(withJSONObject: object))
    }

    @Test func decodesPrivateCarrierEndpointWithoutOptionalMetadata() throws {
        let endpoint = try decode(response())
        #expect(endpoint.transport == "cmux-remote")
        #expect(endpoint.route == "ws://10.0.0.2:7777/v1/link")
        #expect(endpoint.token == "lease-ledger-secret")
        #expect(endpoint.session == "cloud")
        #expect(endpoint.trustedCarrier)
        #expect(endpoint.expiresAtUnix == 1_900_000_000)
        #expect(endpoint.daemonBuild == nil)
        #expect(endpoint.invitation == nil)
        #expect(endpoint.networkAddresses == nil)
    }

    @Test func preservesDaemonBuildAndBothPrivateAddresses() throws {
        var object = response()
        object["daemonBuild"] = ["commit": "abc123", "remoteProtocol": 3, "version": "0.1"]
        object["networkAddresses"] = ["ipv4": "10.0.0.2", "ipv6": "fd00::2"]
        let endpoint = try decode(object)
        #expect(endpoint.daemonBuild == CmxCloudDaemonBuild(commit: "abc123", remoteProtocol: 3, version: "0.1"))
        #expect(endpoint.networkAddresses == CmxCloudNetworkAddresses(ipv4: "10.0.0.2", ipv6: "fd00::2"))
        #expect(try JSONDecoder().decode(CmxCloudAttachEndpoint.self, from: JSONEncoder().encode(endpoint)) == endpoint)
    }

    @Test func preservesNullBuildFieldsAndSingleAddressFamily() throws {
        var object = response()
        object["daemonBuild"] = ["commit": NSNull(), "remoteProtocol": NSNull(), "version": NSNull()]
        object["networkAddresses"] = ["ipv6": "fd00::2"]
        let endpoint = try decode(object)
        #expect(endpoint.daemonBuild == CmxCloudDaemonBuild(commit: nil, remoteProtocol: nil, version: nil))
        #expect(endpoint.networkAddresses == CmxCloudNetworkAddresses(ipv6: "fd00::2"))
    }

    @Test func doesNotInferCarrierTrustFromSecureRouteOrInvitation() throws {
        var object = response()
        object["route"] = "wss://machine.example/v1/link?token=route-secret"
        object["trustedCarrier"] = false
        object["invitation"] = [
            "uri": "cmux://enroll/enrollment-secret",
            "invitationId": "invitation-secret",
            "expiresAtUnix": 1_899_999_000,
        ]
        let endpoint = try decode(object)
        #expect(!endpoint.trustedCarrier)
        let invitation = try #require(endpoint.invitation)
        #expect(invitation.uri == "cmux://enroll/enrollment-secret")
        #expect(invitation.invitationId == "invitation-secret")
        #expect(invitation.expiresAt == Date(timeIntervalSince1970: 1_899_999_000))
        #expect(try CmxCloudAttach().decode(JSONEncoder().encode(endpoint)) == endpoint)
        for diagnostic in [String(describing: endpoint), String(reflecting: endpoint), String(describing: invitation), String(reflecting: invitation)] {
            #expect(!diagnostic.contains("secret"))
            #expect(!diagnostic.contains("machine.example"))
        }
    }

    @Test(arguments: ["ssh", "websocket", "future-transport"])
    func rejectsUnsupportedTransportBeforeReadingItsFields(_ transport: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["transport": transport])
        #expect(throws: CmxCloudAttachError.unsupportedTransport(transport)) {
            _ = try CmxCloudAttach().decode(data)
        }
        #expect(throws: CmxCloudAttachError.unsupportedTransport(transport)) {
            _ = try JSONDecoder().decode(CmxCloudAttachEndpoint.self, from: data)
        }
    }

    @Test(arguments: ["transport", "route", "token", "expiresAtUnix", "session", "trustedCarrier"])
    func rejectsMissingAndNullRequiredFields(_ key: String) throws {
        var object = response()
        object.removeValue(forKey: key)
        #expect(throws: DecodingError.self) { _ = try decode(object) }
        object[key] = NSNull()
        #expect(throws: DecodingError.self) { _ = try decode(object) }
    }

    @Test(arguments: ["transport", "route", "token", "expiresAtUnix", "session", "trustedCarrier", "daemonBuild", "invitation", "networkAddresses"])
    func rejectsMalformedFieldTypes(_ key: String) throws {
        var object = response()
        object[key] = ["unexpected": "object"]
        // Objects are legal for metadata, but their recognized fields must have
        // the backend's declared types.
        if key == "daemonBuild" { object[key] = ["remoteProtocol": "invalid"] }
        if key == "networkAddresses" { object[key] = ["ipv4": 123] }
        #expect(throws: DecodingError.self) { _ = try decode(object) }
    }

    @Test(arguments: [-1.0, 0.0, 1_900_000_000.0])
    func preservesExpiryIncludingAlreadyExpiredValues(_ timestamp: Double) throws {
        var object = response()
        object["expiresAtUnix"] = timestamp
        let endpoint = try decode(object)
        #expect(endpoint.expiresAtUnix == timestamp)
        #expect(endpoint.expiresAt == Date(timeIntervalSince1970: timestamp))
        let invitation = CmxCloudAttachInvitation(uri: "cmux://enroll/test", invitationId: "test", expiresAtUnix: timestamp)
        #expect(invitation.expiresAt == endpoint.expiresAt)
    }

    @Test func initializerAndCodecRoundTripWithoutLegacyFields() throws {
        let endpoint = CmxCloudAttachEndpoint(
            route: "ws://10.0.0.2:7777/v1/link",
            token: "lease-ledger-secret",
            expiresAtUnix: 1_900_000_000,
            session: "cloud",
            trustedCarrier: true
        )
        let encoded = try JSONEncoder().encode(endpoint)
        #expect(try CmxCloudAttach().decode(encoded) == endpoint)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["url"] == nil)
        #expect(object["sessionId"] == nil)
        #expect(object["daemon"] == nil)
        #expect(object["headers"] == nil)
    }
}
