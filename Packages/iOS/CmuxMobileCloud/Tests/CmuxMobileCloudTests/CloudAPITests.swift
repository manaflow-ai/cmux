import Foundation
import Testing
@testable import CmuxMobileCloud

@Suite struct CloudAPIRequestBuilderTests {
    private let builder = CloudAPIRequestBuilder(baseURL: "https://cmux.example/")

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func listCarriesStackHeaders() throws {
        let request = try builder.listMachines(accessToken: "acc", refreshToken: "ref")
        #expect(request.url?.absoluteString == "https://cmux.example/api/vm")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer acc")
        #expect(request.value(forHTTPHeaderField: "X-Stack-Refresh-Token") == "ref")
        #expect(request.httpBody == nil)
    }

    @Test func enrollSendsOnlyThePublicKey() throws {
        let request = try builder.enrollTunnel(
            clientPublicKey: "pub", deviceFingerprint: "ios-1", deviceName: "  ",
            accessToken: "acc", refreshToken: "ref"
        )
        #expect(request.url?.path == "/api/vm/tunnel")
        #expect(request.httpMethod == "POST")
        let json = try body(request)
        #expect(json["clientPublicKey"] as? String == "pub")
        #expect(json["deviceFingerprint"] as? String == "ios-1")
        #expect(json["deviceName"] == nil)
        #expect(json.keys.sorted() == ["clientPublicKey", "deviceFingerprint"])
    }

    @Test func attachUsesCmuxRemoteTransportAndLongTimeout() throws {
        let request = try builder.openAttach(
            machineID: "vm a/b", deviceFingerprint: "ios-1", clientCapabilities: ["Bad Token", "direct-ws-user-agent", "direct-ws-user-agent"],
            accessToken: "acc", refreshToken: "ref"
        )
        #expect(request.url?.absoluteString == "https://cmux.example/api/vm/vm%20a%2Fb/attach-endpoint")
        #expect(request.timeoutInterval == CloudAPIRequestBuilder.attachTimeout)
        let json = try body(request)
        #expect(json["transport"] as? String == "cmux-remote")
        #expect(json["clientCapabilities"] as? [String] == ["direct-ws-user-agent"])
    }

    @Test func approveTargetsTheMachineAndInvitation() throws {
        let request = try builder.approveEnrollment(machineID: "vm1", invitationId: "inv", accessToken: "a", refreshToken: "r")
        #expect(request.url?.path == "/api/vm/vm1/cmux-remote/approve")
        #expect(try body(request)["invitationId"] as? String == "inv")
    }

    @Test func emptyMachineIDIsRejected() {
        #expect(throws: CloudAPIError.self) {
            try builder.openAttach(machineID: " ", deviceFingerprint: "f", clientCapabilities: [], accessToken: "a", refreshToken: "r")
        }
    }
}

@Suite struct CloudAPIResponseDecodingTests {
    private let decoding = CloudAPIResponseDecoding()

    @Test func decodesMachinesWithDefaults() throws {
        let data = Data("""
        {"vms":[{"id":"vm1","provider":"freestyle","status":"running","displayName":"dev","image":"x"},
                {"id":"vm2","provider":"freestyle","status":" ","displayName":""}]}
        """.utf8)
        let machines = try decoding.machines(from: data)
        #expect(machines == [
            CloudMachine(id: "vm1", provider: "freestyle", status: "running", displayName: "dev"),
            CloudMachine(id: "vm2", provider: "freestyle", status: "unknown", displayName: nil),
        ])
        #expect(machines[0].preferredName == "dev")
        #expect(machines[1].preferredName == "vm2")
        #expect(machines[0].isRunning)
    }

    @Test func rejectsMachinesWithoutID() {
        #expect(throws: CloudAPIError.self) {
            try decoding.machines(from: Data(#"{"vms":[{"provider":"freestyle"}]}"#.utf8))
        }
    }

    @Test func decodesEnrollment() throws {
        let enrollment = try decoding.tunnelEnrollment(from: Data(Fixtures.enrollmentJSON.utf8))
        #expect(enrollment.tunnelId == "tun_1")
        #expect(enrollment.routes == ["10.0.0.0/8", "fd00::/8"])
        #expect(enrollment.addressV6 == "fd7a:7570:6c6b::7")
        #expect(enrollment.endpointPort == 51820)
        #expect(enrollment.created)
        #expect(enrollment.clientConfig.hasPrefix("[Interface]"))
    }

    @Test func decodesAttachWithAndWithoutInvitation() throws {
        let first = try decoding.attachEndpoint(from: Data("""
        {"transport":"cmux-remote","route":"ws://[fd00::10]:1337/v1/link","token":"t","session":"s",
         "invitation":{"uri":"cmux-remote+invite://x","invitationId":"inv1","expiresAtUnix":1}}
        """.utf8))
        #expect(first == CloudAttachEndpoint(route: "ws://[fd00::10]:1337/v1/link", session: "s", invitation: .init(uri: "cmux-remote+invite://x", invitationId: "inv1")))
        let second = try decoding.attachEndpoint(from: Data(#"{"transport":"cmux-remote","route":"ws://h/v1/link","token":"t","session":"s"}"#.utf8))
        #expect(second.invitation == nil)
        #expect(throws: CloudAPIError.self) {
            try decoding.attachEndpoint(from: Data(#"{"transport":"legacy","route":"x","session":"s"}"#.utf8))
        }
    }

    @Test func readsErrorMessages() {
        #expect(decoding.errorMessage(from: Data(#"{"error":"vm_not_found","message":"No such machine"}"#.utf8)) == "No such machine")
        #expect(decoding.errorMessage(from: Data("nope".utf8)) == nil)
    }
}

@Suite struct CloudSessionFailureTests {
    @Test func classifiesAPIErrors() {
        #expect(CloudSessionFailure.classify(CloudAPIError.notSignedIn, stage: .list).kind == .signedOut)
        #expect(CloudSessionFailure.classify(CloudAPIError.httpStatus(401, message: nil), stage: .tunnel).kind == .signedOut)
        #expect(CloudSessionFailure.classify(CloudAPIError.httpStatus(503, message: "down"), stage: .tunnel).kind == .controlPlane(status: 503))
        #expect(CloudSessionFailure.classify(CloudDeviceIdentityResolver.Failure.storeUnavailable, stage: .tunnel).kind == .identity)
        #expect(CloudSessionFailure.classify(StubError(message: "x"), stage: .tunnel).kind == .tunnel)
        #expect(CloudSessionFailure.classify(StubError(message: "x"), stage: .link).kind == .link)
    }
}
