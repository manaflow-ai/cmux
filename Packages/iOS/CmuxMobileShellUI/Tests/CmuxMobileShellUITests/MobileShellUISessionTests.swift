#if canImport(UIKit)
import CmuxMobileBrowser
import CmuxMobileBrowserStream
import CmuxMobileShell
import CmuxMobileTerminal
import Testing

@testable import CmuxMobileShellUI

@Suite("Mobile shell UI session ownership")
struct MobileShellUISessionTests {
    private struct ExpectedFailure: Error {}

    @MainActor
    @Test("one session retains the exact composite-owned environment graph")
    func retainsExactEnvironmentGraph() {
        var simulatorStore: MobileSimulatorStreamStore? = MobileSimulatorStreamStore()
        var browserStore: BrowserSurfaceStore? = BrowserSurfaceStore()
        var browserStreamStore: BrowserStreamStore? = BrowserStreamStore()
        weak var retainedSimulatorStore = simulatorStore
        weak var retainedBrowserStore = browserStore
        weak var retainedBrowserStreamStore = browserStreamStore
        let shellStore = MobileShellComposite(simulatorStreamStore: simulatorStore!)
        let runtimeOwner = GhosttyRuntimeOwner { throw ExpectedFailure() }
        let session = MobileShellUISession(
            store: shellStore,
            browserStore: browserStore!,
            browserStreamStore: browserStreamStore!,
            terminalRuntimeOwner: runtimeOwner
        )

        simulatorStore = nil
        browserStore = nil
        browserStreamStore = nil

        #expect(session.store === shellStore)
        #expect(session.simulatorStreamStore === retainedSimulatorStore)
        #expect(session.browserStore === retainedBrowserStore)
        #expect(session.browserStreamStore === retainedBrowserStreamStore)
        #expect(session.terminalRuntimeOwner === runtimeOwner)
    }
}
#endif
