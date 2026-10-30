import CmuxNextCloud
import Foundation
import Testing

@Suite
struct CloudMachineTeamMetadataTests {
    @Test func decodesCreatorAndVisibilityWhenPresent() throws {
        let data = #"{"id":"vm-team","provider":"freestyle","status":"running","createdBy":"user-a","visibility":"team"}"#.data(using: .utf8)!
        let machine = try JSONDecoder().decode(CloudMachine.self, from: data)
        #expect(machine.createdBy == "user-a")
        #expect(machine.visibility == "team")
    }

    @Test func legacyResponsesKeepMetadataAbsent() throws {
        let data = #"{"id":"vm-old","provider":"freestyle","status":"running"}"#.data(using: .utf8)!
        let machine = try JSONDecoder().decode(CloudMachine.self, from: data)
        #expect(machine.createdBy == nil)
        #expect(machine.visibility == nil)
    }
}
