/// The pure frame-progression analysis behind the DEBUG vsync IOSurface
/// timeline UI-test scenario (the split-close-right blank-flash /
/// stretched-text regression probe).
///
/// The app target drives a `CVDisplayLink` that, once per compositor frame,
/// samples each terminal target's IOSurface-backed layer on the main thread
/// and feeds the resulting ``VsyncFrameSample`` values for that frame into
/// ``ingest(frameSamples:)``. This analyzer advances the frame counter,
/// records the first blank frame and the first size-mismatch seen at or after
/// the close mutation, and appends the trace lines, exactly as the legacy
/// in-callback logic did. It holds no AppKit, `CVDisplayLink`, or
/// `GhosttySurfaceScrollView` references, so the value-bearing detection and
/// trace logic lives here while the display-link lifecycle, the
/// `NSLock`-guarded in-flight coordination, and the live layer reads stay in
/// the app target (an irreducible QuartzCore/`GhosttySurfaceScrollView` seam).
///
/// Isolation: not `Sendable`. The app constructs and mutates it only inside
/// its `DispatchQueue.main.sync` capture block (single-threaded access),
/// matching the legacy mutation site, so it carries no synchronization itself.
public final class VsyncIOSurfaceTimelineAnalyzer {
    /// The total number of frames the timeline captures.
    public let frameCount: Int
    /// The frame index at/after which blank and size-mismatch detection arms
    /// (frames before the close mutation are warmup and ignored).
    public let closeFrame: Int

    /// The number of frames ingested so far.
    public private(set) var framesWritten = 0
    /// The first blank frame seen at/after ``closeFrame``, if any.
    public private(set) var firstBlank: (label: String, frame: Int)?
    /// The first compositor size-mismatch seen at/after ``closeFrame`` on a
    /// stretch-risk layer, if any.
    public private(set) var firstSizeMismatch: (label: String, frame: Int, ios: String, expected: String)?
    /// The per-target per-frame trace lines (capped at 200 entries).
    public private(set) var trace: [String] = []

    /// Creates an analyzer for a timeline of `frameCount` frames whose
    /// detection arms at `closeFrame`.
    public init(frameCount: Int, closeFrame: Int) {
        self.frameCount = frameCount
        self.closeFrame = closeFrame
    }

    /// Whether the timeline has ingested all of its frames.
    public var isComplete: Bool { framesWritten >= frameCount }

    /// Ingests the samples for the current frame (one per target), updating
    /// the blank / size-mismatch detection and trace, then advances the frame
    /// counter.
    ///
    /// A no-op once ``isComplete`` is true, matching the legacy
    /// `framesWritten < frameCount` guard.
    public func ingest(frameSamples: [VsyncFrameSample]) {
        guard framesWritten < frameCount else { return }

        for s in frameSamples {
            let iosW = s.iosurfaceWidthPx
            let iosH = s.iosurfaceHeightPx
            let expW = s.expectedWidthPx
            let expH = s.expectedHeightPx
            let gravity = s.layerContentsGravity
            let hasDimensions = iosW > 0 && iosH > 0 && expW > 0 && expH > 0
            let dw = hasDimensions ? abs(iosW - expW) : 0
            let dh = hasDimensions ? abs(iosH - expH) : 0
            let hasSizeMismatch = hasDimensions && (dw > 2 || dh > 2)
            let stretchRisk = s.isStretchRisk

            // Ignore setup/warmup frames before the close action. We only care about
            // regressions that happen at/after the close mutation.
            if firstBlank == nil, framesWritten >= closeFrame, s.isProbablyBlank {
                firstBlank = (label: s.label, frame: framesWritten)
            }

            if firstSizeMismatch == nil,
               framesWritten >= closeFrame,
               stretchRisk,
               hasSizeMismatch {
                firstSizeMismatch = (
                    label: s.label,
                    frame: framesWritten,
                    ios: "\(iosW)x\(iosH)",
                    expected: "\(expW)x\(expH)"
                )
            }

            if trace.count < 200 {
                trace.append("\(framesWritten):\(s.label):blank=\(s.isProbablyBlank ? 1 : 0):ios=\(iosW)x\(iosH):exp=\(expW)x\(expH):gravity=\(gravity):key=\(s.layerContentsKey)")
            }
        }

        framesWritten += 1
    }
}
