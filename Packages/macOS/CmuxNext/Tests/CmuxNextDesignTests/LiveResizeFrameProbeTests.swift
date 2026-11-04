#if DEBUG || CMUX_BENCH_HOOKS
import Foundation
@testable import CmuxNextDesign
import Testing

/// FRAME OWNER REFACTOR S7's live-resize probe (`debug.motion` `liveResize.*` samples) places each `setFrame` on the
/// display's refresh from the window's last display-link frame: the first display time at or after it.
@MainActor
struct LiveResizeFrameProbeTests {
    @Test func aSetFrameAimsAtTheFirstDisplayTimeAfterItOnARecentLink() throws {
        // The link's last frame shows at 10.008 s; the display refreshes every 8 ms.
        #expect(LiveResizeFrameProbe.target(after: 10.002, frameTarget: 10.008, interval: 0.008) == 10.008,
                "before the frame's display time: that one")
        let next = try #require(LiveResizeFrameProbe.target(after: 10.009, frameTarget: 10.008, interval: 0.008))
        #expect(abs(next - 10.016) < 1e-9, "after the frame's display time, the next one: \(next)")
        let later = try #require(LiveResizeFrameProbe.target(after: 10.030, frameTarget: 10.008, interval: 0.008))
        #expect(abs(later - 10.032) < 1e-9, "three refreshes on: \(later)")
    }

    @Test func noDisplayTimeWithoutARecentLinkFrameOrARefreshPeriod() {
        #expect(LiveResizeFrameProbe.target(after: 10.2, frameTarget: 10.008, interval: 0.008) == nil, "a link idle for 0.2 s places nothing")
        #expect(LiveResizeFrameProbe.target(after: 10.002, frameTarget: 10.008, interval: 0) == nil, "no refresh period")
        #expect(LiveResizeFrameProbe.target(after: 10.002, frameTarget: 10.008, interval: .infinity) == nil, "no refresh period")
    }
}
#endif
