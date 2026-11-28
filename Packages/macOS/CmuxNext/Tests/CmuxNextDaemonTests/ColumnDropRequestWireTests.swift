import Foundation
import Testing
@testable import CmuxNextDaemon

/// The exact request lines a column drop sends: the target is a screen or a pane, and only that one goes on the
/// wire. These bytes are the contract the generated type (swift_app `one_of`) keeps with the hand-written one
/// it replaced.
struct ColumnDropRequestWireTests {
    private func line(_ request: some DaemonRequest) throws -> String {
        String(decoding: try WireCoding.encodeRequest(request, id: 7), as: UTF8.self)
    }

    @Test func moveTabGroupToColumnSendsTheTargetItHolds() throws {
        #expect(try line(MoveTabGroupToColumnRequest(group: "tg_1", target: .screen(2)))
            == #"{"cmd":"move-tab-group-to-column","group":"tg_1","id":7,"screen":2}"#)
        #expect(try line(MoveTabGroupToColumnRequest(group: "tg_1", target: .pane(3), afterColumn: 4, width: 0.5,
                                                     transaction: "tx1"))
            == #"{"after_column":4,"cmd":"move-tab-group-to-column","group":"tg_1","id":7,"pane":3,"transaction":"tx1","width":0.5}"#)
        #expect(MoveTabGroupToColumnRequest.requiredCapability == "tab-groups-v1")
    }
}
