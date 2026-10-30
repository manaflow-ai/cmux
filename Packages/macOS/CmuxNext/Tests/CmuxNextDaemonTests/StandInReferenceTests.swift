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
