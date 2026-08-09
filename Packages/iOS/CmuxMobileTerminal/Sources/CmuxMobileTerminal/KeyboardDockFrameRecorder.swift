#if canImport(UIKit)
import CoreGraphics

/// Accumulates display-link evidence that the visible dock content reaches the
/// system-owned input accessory edge on every software-keyboard frame.
struct KeyboardDockFrameRecorder {
    struct Sample {
        let keyboardUp: Bool
        let composerMaxY: CGFloat
        let toolbarMaxY: CGFloat
        let boundsHeight: CGFloat
        let accessoryBottomY: CGFloat
        let gap: CGFloat?
    }

    private(set) var sampleCount = 0
    private(set) var keyboardFrameCount = 0
    private(set) var detachedFrameCount = 0
    private(set) var maxGap: CGFloat = 0
    private(set) var worstSample: Sample?

    mutating func record(_ sample: Sample) {
        sampleCount += 1
        guard sample.keyboardUp, let gap = sample.gap else { return }

        keyboardFrameCount += 1
        if worstSample == nil || gap >= maxGap {
            maxGap = gap
            worstSample = sample
        }
        if gap > 1 {
            detachedFrameCount += 1
        }
    }
}
#endif
