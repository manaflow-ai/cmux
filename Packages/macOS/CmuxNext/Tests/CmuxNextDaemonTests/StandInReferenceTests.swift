import Testing
@testable import CmuxNextDaemon

/// P0 2026-10-30, rule (b): DEBUG builds stop at a request that names a stand-in (a pending create's pane handle or tab
/// surface) as a pane or surface reference (`DaemonRequestExecutor.perform`); the daemon does not know one.
@MainActor struct StandInReferenceTests {
    @Test func aStandInPaneOrSurfaceIsFound() {
        let standIn = ProvisionalPane()
        #expect(DaemonRequestExecutor.standInReference(in: SplitRequest(pane: standIn.handle, direction: .down)) != nil)
        #expect(DaemonRequestExecutor.standInReference(in: NewTabRequest(pane: standIn.handle)) != nil)
        #expect(DaemonRequestExecutor.standInReference(in: CloseTabRequest(surface: ProvisionalTab().surface)) != nil)
    }

    @Test func daemonIdsAndClientMintedIdsAreNot() {
        var options = SpawnOptions(cwd: "/tmp")
        let standIn = ProvisionalPane()
        options.paneID = standIn.paneID // a client-minted public id is the request's own key, not a reference
        options.tabID = standIn.tabID
        #expect(DaemonRequestExecutor.standInReference(in: SplitRequest(pane: PaneID(rawValue: 3), direction: .down, options: options)) == nil)
        #expect(DaemonRequestExecutor.standInReference(in: NewTabRequest(pane: PaneID(rawValue: 3))) == nil)
    }
}

/// The same check on the encoded line, as the request boundary runs it before a request goes out (a non-create pane verb
/// that names a stand-in is refused there with `PaneNotReady`, never sent).
@MainActor struct StandInLineTests {
    @Test func anEncodedLineThatNamesAStandInIsCaught() throws {
        let standIn = ProvisionalPane()
        let leaking = try WireCoding.encodeRequest(ZoomPaneRequest(pane: standIn.handle), id: 7)
        #expect(DaemonRequestExecutor.mayNameStandIn(leaking))
        #expect(DaemonRequestExecutor.standInReference(inLine: leaking) != nil)
        let daemon = try WireCoding.encodeRequest(ZoomPaneRequest(pane: PaneID(rawValue: 3)), id: 8)
        #expect(!DaemonRequestExecutor.mayNameStandIn(daemon))
        // A stand-in's digits in text (a line typed into a terminal) are not a pane reference.
        let text = try WireCoding.encodeRequest(SendInputRequest(surface: SurfaceID(rawValue: 9), text: "\(standIn.handle.rawValue)"), id: 9)
        #expect(DaemonRequestExecutor.standInReference(inLine: text) == nil)
    }
}
