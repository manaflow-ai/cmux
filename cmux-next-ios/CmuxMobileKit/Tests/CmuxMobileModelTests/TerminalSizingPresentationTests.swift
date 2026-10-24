import Foundation
import Testing
@testable import CmuxMobileModel

/// The phone's view of a shared terminal's size (cmux-next-ios/PROTOCOL.md
/// "Terminal sizing policy"): the Connected Devices rows say who is
/// connected, the size each one asks for and who sets the grid; the
/// Priority Order list ranks every device in sight by its token.
@MainActor @Suite struct TerminalSizingPresentationTests {
    /// This Mac's pane (c1), this phone (c2, device ios-1), another phone
    /// that left the screen (c3, device ios-2) and another Mac (c4).
    private let wire: [String: Any] = [
        "generation": 4, "cols": 53, "rows": 39, "reason": "smallest", "owners": ["c2"],
        "policy": ["mode": "smallest", "priority": [], "fixed": NSNull()],
        "participants": [
            ["id": "c1", "device_kind": "mac", "device_name": "Mac mini", "viewport": ["cols": 120, "rows": 39], "counts": true],
            ["id": "c2", "device_kind": "iphone", "device_name": "Aziz's iPhone", "device_id": "ios-1",
             "viewport": ["cols": 53, "rows": 40], "counts": true],
            ["id": "c3", "device_kind": "iphone", "device_name": "Test iPhone", "device_id": "ios-2", "viewport": NSNull(), "counts": false],
            ["id": "c4", "device_kind": "mac", "viewport": ["cols": 200, "rows": 60], "counts": true],
        ],
    ]

    private func presentation() throws -> TerminalSizingPresentation {
        let state = try #require(TerminalSizeState.decode(wire))
        return TerminalSizingPresentation(state: state, selfParticipant: "c2", macParticipants: ["c1"], thisDeviceID: "ios-1")
    }

    @Test func decodesTheDaemonsSizeState() throws {
        let state = try #require(TerminalSizeState.decode(wire))
        #expect(state.generation == 4)
        #expect(state.grid == TerminalGrid(cols: 53, rows: 39))
        #expect(state.reason == "smallest")
        #expect(state.owners == ["c2"])
        #expect(state.participants.map(\.id) == ["c1", "c2", "c3", "c4"])
        #expect(state.participants[1].deviceID == "ios-1")
        #expect(state.participants[2].viewport == nil)
        #expect(state.participants[2].counts == false)
    }

    @Test func rowsNameEveryViewerWithTheSizeItAsksFor() throws {
        let rows = try presentation().rows
        #expect(rows.map(\.title) == ["This Mac", "This iPhone", "Test iPhone", "Another Mac"])
        #expect(rows.map(\.detail) == ["120×39", "53×40", "Not showing it", "200×60"])
        #expect(rows.map(\.setsSize) == [false, true, false, false])
    }

    @Test func saysWhyTheGridHasItsSize() throws {
        let presentation = try presentation()
        #expect(presentation.gridTitle == "53 × 39")
        #expect(presentation.reasonText == "Fits the smallest viewer: This iPhone")
        var latest = presentation
        latest.state?.reason = "latest"
        latest.state?.owners = ["c1"]
        #expect(latest.reasonText == "Set by This Mac")
    }

    @Test func priorityOrderListsStoredTokensThenEveryDeviceInSight() throws {
        let rows = try presentation().orderRows(["device:ios-2", "device:gone"])
        #expect(rows.map(\.token) == ["device:ios-2", "device:gone", "mac", "device:ios-1"])
        #expect(rows.map(\.title) == ["Test iPhone", "Another device", "This Mac", "This iPhone"])
    }

    @Test func reorderingProducesTheTokenOrder() throws {
        let rows = try presentation().orderRows([])
        #expect(rows.map(\.token) == ["mac", "device:ios-1", "device:ios-2"])
        // Drag This iPhone to the top.
        let order = TerminalSizingPresentation.reordered(rows, from: IndexSet(integer: 1), to: 0)
        #expect(order == ["device:ios-1", "mac", "device:ios-2"])
        // Drag This Mac to the end.
        #expect(TerminalSizingPresentation.reordered(rows, from: IndexSet(integer: 0), to: 3) == ["device:ios-1", "device:ios-2", "mac"])
    }

    @Test func policyWireAndUnknownModes() {
        let policy = HostSizePolicy(mode: .priority, order: ["mac", "device:ios-1"])
        #expect(policy.wire["mode"] as? String == "priority")
        #expect(policy.wire["order"] as? [String] == ["mac", "device:ios-1"])
        #expect(HostSizeMode(wire: "bogus") == .smallest)
        let reply: [String: Any] = ["policy": ["mode": "mac"], "mac_participants": ["c1"]]
        let info = HostSizePolicyInfo.decode(reply)
        #expect(info == HostSizePolicyInfo(policy: HostSizePolicy(mode: .mac), macParticipants: ["c1"]))
    }

    @Test func liveStateKeepsTheNewestGeneration() throws {
        let live = TerminalSizingLive()
        let state = try #require(TerminalSizeState.decode(wire))
        live.apply(state, selfParticipant: "c2")
        #expect(live.selfIsOwner)
        var older = state
        older.generation = 3
        older.owners = ["c1"]
        live.apply(older, selfParticipant: nil)
        #expect(live.state?.generation == 4)
        live.apply(older, selfParticipant: nil, reset: true)
        #expect(live.selfIsOwner == false)
    }
}
