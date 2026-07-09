import Testing
@testable import CmuxTestSupport

@Suite("VsyncIOSurfaceTimelineAnalyzer")
struct VsyncIOSurfaceTimelineAnalyzerTests {
    private func sample(
        label: String = "TL",
        blank: Bool = false,
        ios: (Int, Int) = (100, 100),
        expected: (Int, Int) = (100, 100),
        gravity: String = "topLeft",
        stretchRisk: Bool = false,
        key: String = "k"
    ) -> VsyncFrameSample {
        VsyncFrameSample(
            label: label,
            isProbablyBlank: blank,
            iosurfaceWidthPx: ios.0,
            iosurfaceHeightPx: ios.1,
            expectedWidthPx: expected.0,
            expectedHeightPx: expected.1,
            layerContentsGravity: gravity,
            isStretchRisk: stretchRisk,
            layerContentsKey: key
        )
    }

    @Test("advances framesWritten once per ingest and completes at frameCount")
    func framesAdvance() {
        let a = VsyncIOSurfaceTimelineAnalyzer(frameCount: 3, closeFrame: 0)
        #expect(a.framesWritten == 0)
        a.ingest(frameSamples: [sample()])
        a.ingest(frameSamples: [sample()])
        #expect(a.framesWritten == 2)
        #expect(a.isComplete == false)
        a.ingest(frameSamples: [sample()])
        #expect(a.framesWritten == 3)
        #expect(a.isComplete)
        // Ingesting past completion is a no-op (frame guard).
        a.ingest(frameSamples: [sample()])
        #expect(a.framesWritten == 3)
    }

    @Test("ignores blank frames before closeFrame, records the first at/after it")
    func blankDetectionArmsAtCloseFrame() {
        let a = VsyncIOSurfaceTimelineAnalyzer(frameCount: 4, closeFrame: 2)
        a.ingest(frameSamples: [sample(label: "TL", blank: true)]) // frame 0, warmup
        a.ingest(frameSamples: [sample(label: "TL", blank: true)]) // frame 1, warmup
        #expect(a.firstBlank == nil)
        a.ingest(frameSamples: [sample(label: "BL", blank: true)]) // frame 2, armed
        #expect(a.firstBlank?.label == "BL")
        #expect(a.firstBlank?.frame == 2)
        // Subsequent blanks do not overwrite the first.
        a.ingest(frameSamples: [sample(label: "TR", blank: true)]) // frame 3
        #expect(a.firstBlank?.label == "BL")
    }

    @Test("records size mismatch only on stretch-risk layers past the threshold")
    func sizeMismatchRequiresStretchRiskAndThreshold() {
        let a = VsyncIOSurfaceTimelineAnalyzer(frameCount: 4, closeFrame: 0)
        // Within threshold (diff 2) -> no mismatch even with stretch risk.
        a.ingest(frameSamples: [sample(ios: (100, 100), expected: (102, 100), stretchRisk: true)])
        #expect(a.firstSizeMismatch == nil)
        // Over threshold but not stretch risk -> no mismatch.
        a.ingest(frameSamples: [sample(ios: (100, 100), expected: (110, 100), stretchRisk: false)])
        #expect(a.firstSizeMismatch == nil)
        // Over threshold and stretch risk -> recorded.
        a.ingest(frameSamples: [sample(label: "TL", ios: (100, 100), expected: (110, 100), stretchRisk: true)])
        #expect(a.firstSizeMismatch?.label == "TL")
        #expect(a.firstSizeMismatch?.frame == 2)
        #expect(a.firstSizeMismatch?.ios == "100x100")
        #expect(a.firstSizeMismatch?.expected == "110x100")
    }

    @Test("missing dimensions never count as a mismatch")
    func zeroDimensionsNoMismatch() {
        let a = VsyncIOSurfaceTimelineAnalyzer(frameCount: 1, closeFrame: 0)
        a.ingest(frameSamples: [sample(ios: (0, 0), expected: (100, 100), stretchRisk: true)])
        #expect(a.firstSizeMismatch == nil)
    }

    @Test("trace line format matches the legacy string and caps at 200")
    func traceFormatAndCap() {
        let a = VsyncIOSurfaceTimelineAnalyzer(frameCount: 1, closeFrame: 0)
        a.ingest(frameSamples: [sample(label: "TL", blank: true, ios: (10, 20), expected: (30, 40), gravity: "resize", key: "abc")])
        #expect(a.trace == ["0:TL:blank=1:ios=10x20:exp=30x40:gravity=resize:key=abc"])

        let capped = VsyncIOSurfaceTimelineAnalyzer(frameCount: 300, closeFrame: 0)
        for _ in 0..<300 { capped.ingest(frameSamples: [sample()]) }
        #expect(capped.trace.count == 200)
    }
}
