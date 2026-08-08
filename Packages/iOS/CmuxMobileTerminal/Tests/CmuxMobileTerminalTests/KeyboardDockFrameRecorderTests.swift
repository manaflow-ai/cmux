#if canImport(UIKit)
import CoreGraphics
import Testing

@testable import CmuxMobileTerminal

@Suite struct KeyboardDockFrameRecorderTests {
    @Test func checksEveryKeyboardFrameAndRetainsWorstGeometry() {
        var recorder = KeyboardDockFrameRecorder()
        recorder.record(sample(keyboardUp: false, gap: nil, composerMaxY: 700))
        recorder.record(sample(keyboardUp: true, gap: 0, composerMaxY: 402))
        recorder.record(sample(keyboardUp: true, gap: 0.75, composerMaxY: 401.25))
        recorder.record(sample(keyboardUp: true, gap: 1.25, composerMaxY: 400.75))

        #expect(recorder.sampleCount == 4)
        #expect(recorder.keyboardFrameCount == 3)
        #expect(recorder.detachedFrameCount == 1)
        #expect(recorder.maxGap == 1.25)
        #expect(recorder.worstSample?.keyboardUp == true)
        #expect(recorder.worstSample?.composerMaxY == 400.75)
        #expect(recorder.worstSample?.toolbarMaxY == 350)
        #expect(recorder.worstSample?.boundsHeight == 874)
    }

    private func sample(
        keyboardUp: Bool,
        gap: CGFloat?,
        composerMaxY: CGFloat
    ) -> KeyboardDockFrameRecorder.Sample {
        KeyboardDockFrameRecorder.Sample(
            keyboardUp: keyboardUp,
            composerMaxY: composerMaxY,
            toolbarMaxY: 350,
            boundsHeight: 874,
            accessoryBottomY: 402,
            gap: gap
        )
    }
}
#endif
