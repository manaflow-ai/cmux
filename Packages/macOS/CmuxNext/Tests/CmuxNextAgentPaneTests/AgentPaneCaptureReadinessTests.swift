#if DEBUG
import CmuxNextAgentPane
import Testing

struct AgentPaneCaptureReadinessTests {
    private func canSettle(attached: Bool = true, loading: Bool = false, chromium: Bool = false,
                           chromiumStarting: Bool = false, chromiumShown: Bool = false, painted: Bool = true) -> Bool {
        AgentPaneCaptureState(attached: attached, loading: loading, chromium: chromium,
                                                chromiumStarting: chromiumStarting, chromiumShown: chromiumShown,
                                                painted: painted).ready
    }

    @Test func chromiumPageMaySettleWhileBackingWebViewLoads() {
        #expect(canSettle(loading: true, chromium: true, chromiumShown: true))
        #expect(canSettle(loading: false, chromium: true, chromiumShown: true))
        #expect(!canSettle(loading: true))
        #expect(canSettle(loading: false))
        #expect(!canSettle(attached: false, loading: true, chromium: true, chromiumShown: true))
    }

    /// #26468: on a cold launch the agent page is to show in Chromium but Chromium has not attached.
    /// Its hidden backing WKWebView is in the window and done loading, which used to settle the
    /// scene with no page on screen, so the snapshot drew 0 web views and 0 Chromium pages.
    @Test func aChromiumPageStillStartingDoesNotSettle() {
        #expect(!canSettle(loading: false, chromiumStarting: true))
        #expect(!canSettle(loading: false, chromium: true, chromiumStarting: true, chromiumShown: true))
    }

    @Test func aChromiumPageTheSnapshotCannotDrawDoesNotSettle() {
        // Attached but parked, hidden, under a clear paint hold or without a size.
        #expect(!canSettle(chromium: true, chromiumShown: false))
    }

    @Test func aPageBeforeItsFirstPaintDoesNotSettle() {
        #expect(!canSettle(loading: false, painted: false))
        #expect(!canSettle(chromium: true, chromiumShown: true, painted: false))
    }
}
#endif
