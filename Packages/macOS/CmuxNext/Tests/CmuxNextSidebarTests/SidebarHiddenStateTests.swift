import AppKit
@testable import CmuxNextSidebar
import Testing

@MainActor
@Suite(.serialized)
struct SidebarHiddenStateTests {
    private final class CountingView: NSView {
        var setterCalls = 0

        override var isHidden: Bool {
            get { super.isHidden }
            set {
                setterCalls += 1
                super.isHidden = newValue
            }
        }
    }

    /// Sidebar layout can run once per resize or width-motion frame. Repeating the same state
    /// must enter AppKit's KVC setter once, rather than once per frame.
    @Test func repeatedLayoutVisibilityIsConstantAtScale() {
        let view = CountingView()
        let frames = 2_000

        for _ in 0..<frames { SidebarHiddenState.apply(true, to: view) }
        #expect(view.setterCalls == 1)
        #expect(view.isHidden)

        for _ in 0..<frames { SidebarHiddenState.apply(false, to: view) }
        #expect(view.setterCalls == 2)
        #expect(!view.isHidden)
    }
}
