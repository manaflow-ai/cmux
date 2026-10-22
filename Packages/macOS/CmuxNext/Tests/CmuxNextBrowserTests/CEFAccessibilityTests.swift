@testable import CmuxNextBrowser
import Testing

/// Chromium builds a page's accessibility tree only when its embedder turns accessibility on
/// (`CefBrowserHost::SetAccessibilityState`). While an assistive client asks for the app's tree,
/// every Chromium page, open now or opened later, has it on; when none asks, it goes off. Before,
/// cmux never turned it on, so an agent page's window read as an empty AXWindow.
@MainActor
@Suite struct CEFAccessibilityTests {
    private final class Spy {
        var browsers: [Int32] = [1, 2]
        var applied: [String] = []
    }

    private func make(_ spy: Spy) -> CEFAccessibility {
        CEFAccessibility(apply: { browser, on in spy.applied.append("\(browser):\(on)") }, browsers: { spy.browsers })
    }

    @Test func turningOnReachesEveryOpenPage() {
        let spy = Spy()
        let accessibility = make(spy)
        accessibility.setEnabled(true)
        #expect(accessibility.isEnabled)
        #expect(spy.applied.sorted() == ["1:true", "2:true"])
        accessibility.setEnabled(true)
        #expect(spy.applied.count == 2)
    }

    @Test func aPageOpenedLaterFollowsTheState() {
        let spy = Spy()
        let accessibility = make(spy)
        accessibility.attached(3)
        #expect(spy.applied.isEmpty)
        accessibility.setEnabled(true)
        spy.applied = []
        accessibility.attached(4)
        #expect(spy.applied == ["4:true"])
    }

    @Test func turningOffReachesEveryOpenPage() {
        let spy = Spy()
        let accessibility = make(spy)
        accessibility.setEnabled(true)
        spy.applied = []
        accessibility.setEnabled(false)
        #expect(!accessibility.isEnabled)
        #expect(spy.applied.sorted() == ["1:false", "2:false"])
    }
}
