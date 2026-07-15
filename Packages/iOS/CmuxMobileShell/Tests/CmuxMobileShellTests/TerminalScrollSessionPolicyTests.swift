import CMUXMobileCore
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite("Terminal scroll session policy")
struct TerminalScrollSessionPolicyTests {
    @Test("rolling prefetch counts exact primary rows instead of alternate wheel ticks")
    func rollingPrefetchCountsPrimaryRows() {
        let harness = TerminalScrollSessionHarness()
        let session = harness.makeSession()
        let run = MobileTerminalScrollRun(
            primaryRows: 1,
            alternateScreenLines: 0.1,
            col: 1,
            row: 1
        )

        #expect(session.prefetchWindow(for: run) == .directional(for: 1))
        for _ in 0..<119 {
            #expect(session.prefetchWindow(for: run) == nil)
        }
        #expect(session.prefetchWindow(for: run) == .directional(for: 1))
    }

    @Test("disconnect recovery preserves the mounted session")
    func disconnectRecoveryPreservesMountedSession() {
        let store = MobileShellComposite.preview()
        let surfaceID = "surface-1"
        let token = store.mountTerminalScrollSession(
            surfaceID: surfaceID,
            cancelLocal: {}
        )
        let originalSession = store.terminalScrollSessionsBySurfaceID[surfaceID]
        let originalEpoch = originalSession?.interactionEpoch

        store.remoteClient = nil

        let recoveredSession = store.terminalScrollSessionsBySurfaceID[surfaceID]
        #expect(recoveredSession?.token == token)
        #expect(recoveredSession === originalSession)
        #expect(recoveredSession?.interactionEpoch != originalEpoch)
        #expect(recoveredSession?.shouldDeferLiveRenderGrid == false)

        store.unmountTerminalScrollSession(surfaceID: surfaceID, token: token)
    }
}
