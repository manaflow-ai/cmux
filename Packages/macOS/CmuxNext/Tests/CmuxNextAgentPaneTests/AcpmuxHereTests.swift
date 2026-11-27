import Foundation
import Testing
@testable import CmuxNextAgentPane

struct AcpmuxHereTests {
    @Test func decodesMembersAndWorkingCounts() {
        let here = AcpmuxHere([
            "here": [
                ["id": "ada", "name": "Ada", "kind": "person", "status": "active", "working": true,
                 "devices": [["device": "air", "deviceKind": "mac", "status": "active", "working": true, "ageMs": 1200]]],
                ["id": "agent-1", "name": "Builder", "kind": "agent", "status": "idle", "working": false],
                ["name": "invalid"]
            ]
        ])
        #expect(here.members.count == 2)
        #expect(here.activeCount == 1)
        #expect(here.workingCount == 1)
        #expect(here.members[0].devices.first?.ageMs == 1200)
    }

    @Test func missingHereIsAnEmptySnapshot() {
        #expect(AcpmuxHere([:]) == AcpmuxHere())
    }
}
