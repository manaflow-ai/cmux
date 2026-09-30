import CmuxTerminalSharing
import CmuxTerminalSizing
import Foundation
import Testing

/// A Mac viewing another Mac's local terminal (Devices) joins the host's
/// shared sizing like a phone, as `device_kind: mac` with its own device id.
@Suite struct RemoteMacTerminalViewerTests {
    private let me = TerminalSharingIdentity(
        userID: "u_l", displayName: "Lawrence", deviceName: "Lawrence's MacBook Pro", deviceID: "laptop"
    )

    private func viewer() -> RemoteMacTerminalViewer {
        RemoteMacTerminalViewer(clientID: "mac-1", identity: me)
    }

    private func state(generation: UInt64, cols: Int = 200, rows: Int = 60) -> TerminalSizingState {
        var engine = TerminalSizingEngine(initialSize: TerminalGridSize(cols: 80, rows: 24))
        engine.attach(me.participant(id: "mac:host", deviceKind: .mac, viewport: TerminalGridSize(cols: cols, rows: rows)))
        var state = engine.state
        state.generation = generation
        return state
    }

    @Test func replayRegistersThePaneAsAMacParticipant() throws {
        var v = viewer()
        #expect(v.replayParams().isEmpty, "no viewport, no registration")
        _ = v.paneResized(TerminalGridSize(cols: 120, rows: 40))
        let params = v.replayParams()
        #expect(params["client_id"] as? String == "mac-1")
        #expect(params["viewport_columns"] as? Int == 120)
        #expect(params["viewport_rows"] as? Int == 40)
        #expect(params["device_kind"] as? String == "mac")
        #expect(params["device_name"] as? String == "Lawrence's MacBook Pro")
        #expect(params["device_id"] as? String == "laptop")
        #expect(params["viewport_generation"] as? Int == 1)
    }

    @Test func paneResizesReportOncePerChangeWithRisingGenerations() throws {
        var v = viewer()
        let first = try #require(v.paneResized(TerminalGridSize(cols: 120, rows: 40)))
        #expect(first["viewport_generation"] as? Int == 1)
        #expect(v.paneResized(TerminalGridSize(cols: 120, rows: 40)) == nil)
        let second = try #require(v.paneResized(TerminalGridSize(cols: 90, rows: 30)))
        #expect(second["viewport_generation"] as? Int == 2)
        #expect(second["viewport_columns"] as? Int == 90)
    }

    @Test func snapshotShowsTheHostGridAndThisViewer() {
        var v = viewer()
        _ = v.paneResized(TerminalGridSize(cols: 120, rows: 40))
        #expect(v.snapshot == nil)
        #expect(v.receive(state(generation: 3), selfParticipantID: "mobile:mac-1"))
        #expect(!v.receive(state(generation: 2), selfParticipantID: "mobile:mac-1"), "older states are ignored")
        let snapshot = v.snapshot
        #expect(snapshot?.selfParticipantID == "mobile:mac-1")
        #expect(snapshot?.state.size == TerminalGridSize(cols: 200, rows: 60))
        #expect(snapshot?.isCloud == false)
    }

    @Test func aDetachStopsReportsUntilReattach() throws {
        var v = viewer()
        _ = v.paneResized(TerminalGridSize(cols: 120, rows: 40))
        v.receive(state(generation: 1), selfParticipantID: "mobile:mac-1")
        let detachment = TerminalSharingDetachment(reason: .disconnectedBy(TerminalDetachActor(displayName: "Kai")), at: Date(timeIntervalSince1970: 0))
        v.detached(detachment)
        #expect(v.snapshot?.detachment == detachment)
        #expect(v.paneResized(TerminalGridSize(cols: 100, rows: 30)) == nil)
        let reattach = v.reattachParams(asViewer: true)
        #expect(reattach["as_viewer"] as? Bool == true)
        #expect(reattach["client_id"] as? String == "mac-1")
        #expect(reattach["viewport_columns"] as? Int == 100)
        #expect(reattach["device_kind"] as? String == "mac")
        v.reattached()
        #expect(v.snapshot?.detachment == nil)
    }

    @Test func countsOverrideRidesOnAViewportReport() throws {
        var v = viewer()
        #expect(v.countsParams(false) == nil, "no viewport yet")
        _ = v.paneResized(TerminalGridSize(cols: 120, rows: 40))
        let viewerOnly = try #require(v.countsParams(false))
        #expect(viewerOnly["counts_override"] as? Bool == false)
        #expect(viewerOnly["viewport_generation"] as? Int == 1, "same grid, same generation")
        let cleared = try #require(v.countsParams(nil))
        #expect(cleared["counts_override"] is NSNull)
    }

    @Test func leavingClearsTheReport() {
        var v = viewer()
        _ = v.paneResized(TerminalGridSize(cols: 120, rows: 40))
        let clear = v.clearParams()
        #expect(clear["clear"] as? Bool == true)
        #expect(clear["client_id"] as? String == "mac-1")
        #expect(clear["viewport_generation"] as? Int == 2)
    }
}
