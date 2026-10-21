import Foundation
import Testing
@testable import CmuxNextDaemon

struct DaemonMachineIdentityTests {
    @Test func identityMetadataEncodingIsExplicitAndDefaultRequestsStayLegacy() throws {
        let legacy = try JSONDecoder().decode(JSONValue.self, from: WireCoding.encodeRequest(IdentifyRequest(), id: 1))
        #expect(legacy == .object(["cmd": .string("identify"), "id": .number(1)]))
        for enabled in [true, false] {
            let wire = try JSONDecoder().decode(JSONValue.self, from: WireCoding.encodeRequest(IdentifyRequest(machineMetadata: enabled), id: 2))
            #expect(wire == .object(["cmd": .string("identify"), "id": .number(2), "machine_metadata": .bool(enabled)]))
        }
    }

    @Test func machineOwnerRemainsDistinctFromSessionAndHostName() throws {
        let identity = try decode(machineField: #", "machine_id":"machine_public-owner""#)
        #expect(identity.machineResourceID == ResourceID(rawValue: "machine_public-owner"))
        #expect(identity.sessionID == "session-registry")
        #expect(identity.machineName == "example-host")
        #expect(identity.machineResourceID?.rawValue != identity.sessionID)
    }

    @Test(arguments: ["", #", "machine_id":null"#, #", "machine_id":"""#])
    func oldOrUnidentifiedOwnersRemainUnknown(machineField: String) throws {
        let identity = try decode(machineField: machineField)
        #expect(identity.machineResourceID == nil)
        #expect(identity.sessionID != nil)
        #expect(identity.machineName != nil)
    }

    @Test(arguments: [#", "machine_id":17"#, #", "machine_id":true"#, #", "machine_id":{}"#])
    func malformedMachineOwnersAreNotCoerced(machineField: String) {
        do {
            _ = try decode(machineField: machineField)
            Issue.record("a non-string owner passed the identity handshake")
        } catch DaemonError.malformedResponse {
            // Malformed ownership must fail instead of choosing a different machine.
        } catch {
            Issue.record("unexpected identity error: \(error)")
        }
    }

    private func decode(machineField: String) throws -> DaemonIdentity {
        let data = Data("""
        {"id":1,"ok":true,"data":{"app":"cmux-tui","protocol":12,
        "registry_id":"SESSION-REGISTRY","machine_name":"example-host",
        "generation":"boot-1"\(machineField)}}
        """.utf8)
        return try WireCoding.decodeResponse(DaemonIdentity.self, from: data)
    }
}
