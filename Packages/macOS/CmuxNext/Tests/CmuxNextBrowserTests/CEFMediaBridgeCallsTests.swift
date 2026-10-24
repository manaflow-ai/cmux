@testable import CmuxNextBrowser
import Foundation
import Testing

/// The Chromium media bridge's DevTools traffic after each binding add. A binding reaches only
/// the worlds that exist when it is added, so the observer may hold a report for it; the bridge
/// calls the observer's ready hook once in the existing worlds right after the adds, which sends
/// that report with no timer in the page (`BrowserMediaObserverIdleTests`).
@Suite struct CEFMediaBridgeCallsTests {
    @Test func theReadyHookRunsOnceAfterTheBindingAdds() throws {
        let calls = CEFMediaBridge.bindingCalls
        let ready = calls.enumerated().filter { if case .once = $0.element { true } else { false } }
        #expect(ready.count == 1)
        let index = try #require(ready.first?.offset)
        let adds = calls.enumerated().filter { $0.element.method == "Runtime.addBinding" }.map(\.offset)
        #expect(!adds.isEmpty && adds.allSatisfy { $0 < index })
        guard case .once(let source, let world) = calls[index] else { return }
        #expect(world == BrowserMediaState.world)
        #expect(source.contains(BrowserMediaState.readyHook))
    }
}
