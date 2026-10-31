import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextSidebar
import Testing

/// Remove Remote Group (`cmux remote remove-group`, MCP with `machine=`) on a machine whose section
/// is not a remote group reported success and changed nothing. It is refused for what it is.
@MainActor @Suite struct RemoteGroupRemoveRefusesTests {
    private func records(hostGroup: Bool?) -> SidebarDocRecords {
        guard let hostGroup else { return SidebarDocRecords() }
        var section = SidebarDocSection(id: "sec_m_mini", kind: .machine(session: "mini"))
        section.hostGroup = hostGroup
        return SidebarDocRecords(revision: 1, sections: ["sec_m_mini": section])
    }

    @Test func aRemoteGroupIsUnmarked() throws {
        let ops = try RemoteGroupHandlers.removalOps(session: "mini", records: records(hostGroup: true))
        #expect(ops.count == 1)
        #expect(ops.first?["op"] as? String == "section.update")
    }

    @Test(arguments: [false, nil] as [Bool?])
    func aSectionThatIsNotARemoteGroupIsRefused(_ hostGroup: Bool?) {
        #expect(throws: ActionFailure.self) {
            try RemoteGroupHandlers.removalOps(session: "mini", records: records(hostGroup: hostGroup))
        }
    }
}
