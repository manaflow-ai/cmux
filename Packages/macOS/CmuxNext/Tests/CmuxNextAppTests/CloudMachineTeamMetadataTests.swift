@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import Testing

@Suite
struct CloudMachineTeamMetadataTests {
    @Test(arguments: ["createdByUserId", "createdBy"])
    func decodesClassicCreatorAndVisibility(creatorKey: String) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": "vm-team", "provider": "freestyle", "status": "running",
            creatorKey: "user-a", "visibility": "team",
        ])
        let machine = try JSONDecoder().decode(CloudMachine.self, from: data)
        #expect(machine.createdBy == "user-a")
        #expect(machine.visibility == "team")
    }

    @Test func appServerRecordsCarryCreatorAndVisibility() throws {
        let record = JSONValue.object([
            "id": .string("vm-shared"), "status": .string("running"),
            "creator": .string("user-b"), "visibility": .string("private"),
        ])
        let machine = try #require(CloudMachine(next: record))
        #expect(machine.createdBy == "user-b")
        #expect(machine.visibility == "private")
    }

    @Test func legacyResponsesKeepMetadataAbsent() throws {
        let data = Data(#"{"id":"vm-old","provider":"freestyle","status":"running"}"#.utf8)
        let machine = try JSONDecoder().decode(CloudMachine.self, from: data)
        #expect(machine.createdBy == nil)
        #expect(machine.visibility == nil)
        let next = try #require(CloudMachine(next: .object(["id": .string("vm-old"), "status": .string("running")])))
        #expect(next.createdBy == nil)
        #expect(next.visibility == nil)
    }
}
