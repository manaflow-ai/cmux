@testable import CmuxNextApp
@testable import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import Testing

@Suite
struct CloudMachineTeamMetadataTests {
    @Test(arguments: ["createdByUserId", "createdBy"])
    func decodesClassicCreator(creatorKey: String) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": "vm-team", "provider": "freestyle", "status": "running",
            creatorKey: "user-a",
        ])
        let machine = try JSONDecoder().decode(CloudMachine.self, from: data)
        #expect(machine.createdBy == "user-a")
    }

    // GET /api/vm maps creatorFor(entry, names) into createdBy; the internal
    // createdByUserId field is not part of that response. Exercise the real list decoder.
    @Test func decodesClassicListCreatorObjectsAndNull() throws {
        let data = Data(#"""
        {"vms":[
          {"id":"vm-a","provider":"freestyle","status":"running","displayName":"Shared box","slug":"calm-blue-sky","image":"devbox","imageVersion":null,"kind":"devbox","createdAt":1760000000000,"createdBy":{"userId":"user-a","displayName":"Ada Lovelace"},"address":{"ipv4":null,"ipv6":null}},
          {"id":"vm-b","provider":"freestyle","status":"paused","createdBy":{"userId":"user-b","displayName":null}},
          {"id":"vm-c","provider":"freestyle","status":"running","createdBy":null}
        ],"limits":null}
        """#.utf8)
        let list = try JSONDecoder().decode(CloudMachineList.self, from: data)
        #expect(list.vms.map(\.createdBy) == ["user-a", "user-b", nil])
        #expect(list.vms.map(\.id) == ["vm-a", "vm-b", "vm-c"])
    }

    // POST /api/vm omits status; GET /api/vm/:id includes it. Both use creatorFor.
    @Test(arguments: [
        #"{"id":"vm-new","provider":"freestyle","createdBy":{"userId":"user-a","displayName":"Ada Lovelace"}}"#,
        #"{"id":"vm-new","provider":"freestyle","status":"running","createdBy":{"userId":"user-a","displayName":null}}"#,
    ])
    func decodesClassicCreateAndDetailCreatorObjects(json: String) throws {
        let machine = try JSONDecoder().decode(CloudMachine.self, from: Data(json.utf8))
        #expect(machine.createdBy == "user-a")
    }

    @Test func explicitNullCreatorMetadataStaysAbsent() throws {
        let data = Data(#"{"id":"vm-old","createdByUserId":null,"createdBy":null}"#.utf8)
        let machine = try JSONDecoder().decode(CloudMachine.self, from: data)
        #expect(machine.createdBy == nil)
    }

    @Test(arguments: [
        #"{"id":42,"createdBy":{"userId":"user-a","displayName":null}}"#,
        #"{"id":"vm-bad","createdBy":{"userId":42,"displayName":null}}"#,
    ])
    func malformedFieldsStillFailDecoding(json: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CloudMachine.self, from: Data(json.utf8))
        }
    }

    @Test func appServerRecordsCarryCreator() throws {
        let record = JSONValue.object([
            "id": .string("vm-shared"), "status": .string("running"),
            "creator": .string("user-b"),
        ])
        let machine = try #require(CloudMachine(next: record))
        #expect(machine.createdBy == "user-b")
    }

    @Test func legacyResponsesKeepMetadataAbsent() throws {
        let data = Data(#"{"id":"vm-old","provider":"freestyle","status":"running"}"#.utf8)
        let machine = try JSONDecoder().decode(CloudMachine.self, from: data)
        #expect(machine.createdBy == nil)
        let next = try #require(CloudMachine(next: .object(["id": .string("vm-old"), "status": .string("running")])))
        #expect(next.createdBy == nil)
    }
}
