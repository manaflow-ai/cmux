import Foundation
import Testing
@testable import CmuxNextDaemon

/// The exact request lines the close requests send. `end_terminals` goes on the wire only when true, so a
/// daemon without `batch-close-v1` sees the request it always saw. These bytes are the contract the
/// generated types (swift_app `encode: if_true`) keep with the hand-written ones they replaced.
struct CloseRequestWireTests {
    private func line(_ request: some DaemonRequest) throws -> String {
        String(decoding: try WireCoding.encodeRequest(request, id: 7), as: UTF8.self)
    }

    @Test func closePaneSendsEndTerminalsOnlyWhenTrue() throws {
        #expect(try line(ClosePaneRequest(pane: 3)) == #"{"cmd":"close-pane","id":7,"pane":3}"#)
        #expect(try line(ClosePaneRequest(pane: 3, endTerminals: true))
            == #"{"cmd":"close-pane","end_terminals":true,"id":7,"pane":3}"#)
    }

    @Test func closeScreenSendsEndTerminalsOnlyWhenTrue() throws {
        #expect(try line(CloseScreenRequest(screen: 2)) == #"{"cmd":"close-screen","id":7,"screen":2}"#)
        #expect(try line(CloseScreenRequest(screen: 2, endTerminals: true))
            == #"{"cmd":"close-screen","end_terminals":true,"id":7,"screen":2}"#)
    }

    @Test func closeTabGroupSendsEndTerminalsOnlyWhenTrue() throws {
        #expect(try line(CloseTabGroupRequest(group: "tg_1")) == #"{"cmd":"close-tab-group","group":"tg_1","id":7}"#)
        #expect(try line(CloseTabGroupRequest(group: "tg_1", endTerminals: true))
            == #"{"cmd":"close-tab-group","end_terminals":true,"group":"tg_1","id":7}"#)
        #expect(CloseTabGroupRequest.requiredCapability == "tab-groups-v1")
    }

    @Test func closeTabsSendsOnlyWhatIsSet() throws {
        #expect(try line(CloseTabsRequest(surfaces: [4, 5], endTerminals: false, mutation: nil))
            == #"{"cmd":"close-tabs","id":7,"surfaces":[4,5]}"#)
        let mutation = MutationIdentity(origin: "app", mutationID: "m1")
        #expect(try line(CloseTabsRequest(surfaces: [4], endTerminals: true, transaction: "tx1",
                                          mutation: mutation, reason: .sessionEnd))
            == #"{"cmd":"close-tabs","end_terminals":true,"id":7,"mutation_id":"m1","origin":"app","reason":"session_end","surfaces":[4],"transaction":"tx1"}"#)
        #expect(CloseTabsRequest.requiredCapability == "batch-close-v1")
    }
}
