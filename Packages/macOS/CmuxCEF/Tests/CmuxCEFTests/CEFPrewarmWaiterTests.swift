import Foundation
import Testing
@testable import CmuxCEF

/// The warm-up page closes on its first terminal event or the timeout, and
/// its wait resumes exactly once whichever comes first.
@MainActor
@Suite struct CEFPrewarmWaiterTests {
    @Test func loadEndRendererExitAndCloseEndTheWarmup() {
        #expect(CEFPrewarmWaiter.ends(.loadFinished(httpStatus: 200)))
        #expect(CEFPrewarmWaiter.ends(.loadFailed(code: -1, message: "", url: nil, chromiumInterstitial: false)))
        #expect(CEFPrewarmWaiter.ends(.closed))
        var exited = CEFBrowserState()
        exited.rendererExit = CEFRendererExit(status: 2, code: 11, message: "crashed")
        #expect(CEFPrewarmWaiter.ends(.stateChanged(exited)))
    }

    @Test func progressDoesNotEndTheWarmup() {
        #expect(!CEFPrewarmWaiter.ends(.loadStarted(nil, fromPost: false)))
        #expect(!CEFPrewarmWaiter.ends(.stateChanged(CEFBrowserState())))
        #expect(!CEFPrewarmWaiter.ends(.closeRequested))
    }

    /// A load that ends while `start` runs (synchronous event) is not lost.
    @Test func finishInsideStartIsReturned() async {
        let waiter = CEFPrewarmWaiter()
        let timedOut = await waiter.wait { waiter.finish(timedOut: false) }
        #expect(!timedOut)
    }

    /// The first result wins; a late timeout does not resume twice.
    @Test func firstFinishWins() async {
        let waiter = CEFPrewarmWaiter()
        let timedOut = await waiter.wait {
            Task { @MainActor in
                waiter.finish(timedOut: true)
                waiter.finish(timedOut: false)
            }
        }
        #expect(timedOut)
    }
}
