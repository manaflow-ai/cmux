@testable import CmuxNextBrowser
import Foundation
import Testing

/// The Chromium media bridge's DevTools calls for a document (forks before API 29). The observer
/// keeps no timer while its report waits for the binding (`BrowserMediaState+Scripts`), so every
/// binding add must be followed by the observer's ready hook: an iframe player whose binding came
/// with a later load event shows then, however late.
@Suite struct CEFMediaBridgeCallsTests {
    @Test func everyBindingAddIsFollowedByTheObserversReadyHook() throws {
        let calls = CEFMediaBridge.documentCalls
        #expect(calls.map(\.method).prefix(2) == ["Runtime.addBinding", "Runtime.addBinding"])
        guard case .readyHook(let world, let hook)? = calls.last else {
            Issue.record("no ready hook after the binding adds")
            return
        }
        #expect(world == BrowserMediaState.world)
        #expect(hook == BrowserMediaState.readyHook)
    }

    /// The hook the bridge calls is the one the observer defines, and it sends a waiting report.
    @Test func theReadyHookTheBridgeCallsSendsTheWaitingReport() throws {
        let context = try BrowserMediaObserverIdleTests.context()
        context.evaluateScript("ready = false; var v = video(true); media = [v]; fire('play', v);")
        #expect(BrowserMediaObserverIdleTests.posts(context) == 0)
        guard case .readyHook(_, let hook)? = CEFMediaBridge.documentCalls.last else {
            Issue.record("no ready hook")
            return
        }
        context.evaluateScript("ready = true; " + CEFDocumentCall.readySource(hook: hook) + "; runTimeouts();")
        #expect(BrowserMediaObserverIdleTests.posts(context) == 1)
    }
}
