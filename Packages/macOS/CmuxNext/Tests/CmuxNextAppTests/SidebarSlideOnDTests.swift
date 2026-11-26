import CmuxNextDesignTokens
@testable import CmuxNextSidebar
import Testing

/// instant-splits gap row 5: Cmd-B's slide resizes the panes beside it, so it moves for the panes' one motion length D
/// (`split`, about 100 ms), not `appear`'s 160 ms or `disappear`'s 130 ms (side_open settled at 163 ms on the
/// split-scale bench's lightest cell, against a 120 ms budget).
@MainActor
@Suite struct SidebarSlideOnDTests {
    @Test func theShowAndHideSlideForD() {
        let policy = MotionPolicy(speed: .fast, reduceMotion: false)
        #expect(SidebarContainerView.widthSpring == .split)
        let slide = policy.duration(SidebarContainerView.widthSpring)
        #expect(slide > 0.085 && slide <= 0.105, "the sidebar slides for \(slide * 1000) ms, not D")
        #expect(slide < policy.duration(.appear) && slide < policy.duration(.disappear))
    }
}
