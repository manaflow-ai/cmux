import Foundation
import Testing
@testable import CmuxNextDaemon

/// The exact request lines of the requests that carry a nested object: `move-tab-to-column`'s
/// `dock` and `set-size-policy`'s `policy`. These bytes are the contract the generated types
/// (swift_app `object`) keep with the hand-written ones they replaced.
struct NestedObjectRequestWireTests {
    private func line(_ request: some DaemonRequest) throws -> String {
        String(decoding: try WireCoding.encodeRequest(request, id: 7), as: UTF8.self)
    }

    @Test func aColumnMoveWithoutADockSendsNone() throws {
        #expect(try line(MoveTabToColumnRequest(surface: 7, target: .screen(2)))
            == #"{"cmd":"move-tab-to-column","id":7,"screen":2,"surface":7}"#)
        #expect(MoveTabToColumnRequest.requiredCapability == "tab-drag-v1")
    }

    @Test func aPinnedDockSendsEveryPinField() throws {
        let dock = DockSnapshot(edge: .left, mode: .docked, role: .agentChat, isPinned: true, allowsTabs: true)
        #expect(try line(MoveTabToColumnRequest(surface: 7, target: .pane(3), afterColumn: 4, width: 0.5,
                                                dock: .init(dock), keepFocus: true, transaction: "tx1"))
            == #"{"after_column":4,"cmd":"move-tab-to-column","dock":{"edge":"left","mode":"docked","pinned":true,"role":"agent_chat"},"id":7,"keep_focus":true,"pane":3,"surface":7,"transaction":"tx1","width":0.5}"#)
    }

    @Test func anUnpinnedDockSendsItsEdgeAndModeOnly() throws {
        let dock = DockSnapshot(edge: .right, mode: .overlay)
        #expect(try line(MoveTabToColumnRequest(surface: 7, target: .pane(3), dock: .init(dock)))
            == #"{"cmd":"move-tab-to-column","dock":{"edge":"right","mode":"overlay"},"id":7,"pane":3,"surface":7}"#)
    }

    @Test func aSizePolicySendsItsMode() throws {
        #expect(try line(SetSizePolicyRequest(surface: 7, policy: .init(mode: "latest")))
            == #"{"cmd":"set-size-policy","id":7,"policy":{"mode":"latest"},"surface":7}"#)
        // The schema's gate; the one sender (`TerminalAttachment.takeOver`) already sends only to a daemon with it.
        #expect(SetSizePolicyRequest.requiredCapability == "shared-sizing-v1")
    }
}
