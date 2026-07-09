/// One target's IOSurface-backed layer sample for a single vsync frame, as
/// consumed by ``VsyncIOSurfaceTimelineAnalyzer``.
///
/// The live layer/IOSurface reads (and the `CALayerContentsGravity.resize`
/// comparison that defines ``isStretchRisk``) happen app-side on the main
/// actor, because they touch `GhosttySurfaceScrollView` and QuartzCore. The
/// app hands the resulting plain values here so the analyzer that detects the
/// first blank flash and the first compositor size-mismatch stays a pure,
/// `Sendable`, AppKit-free value transform.
///
/// The field names and types mirror the legacy app-side `DebugFrameSample`
/// fields the timeline analysis read, so the trace string and detection
/// thresholds remain byte-identical.
public struct VsyncFrameSample: Sendable, Equatable {
    /// The label identifying which target this sample came from (e.g. `"TL"`).
    public let label: String
    /// Whether the sampled layer contents are probably blank, as classified
    /// app-side by the legacy `DebugFrameSample.isProbablyBlank` rule.
    public let isProbablyBlank: Bool
    /// The IOSurface width in pixels (`0` when unavailable).
    public let iosurfaceWidthPx: Int
    /// The IOSurface height in pixels (`0` when unavailable).
    public let iosurfaceHeightPx: Int
    /// The expected layer width in pixels (`0` when unavailable).
    public let expectedWidthPx: Int
    /// The expected layer height in pixels (`0` when unavailable).
    public let expectedHeightPx: Int
    /// The layer `contentsGravity` raw value, recorded in the trace.
    public let layerContentsGravity: String
    /// Whether the layer is at stretch risk, i.e. its `contentsGravity`
    /// equals `CALayerContentsGravity.resize`. Computed app-side to keep this
    /// type free of QuartzCore.
    public let isStretchRisk: Bool
    /// The layer contents identity key, recorded in the trace.
    public let layerContentsKey: String

    /// Creates a vsync frame sample.
    public init(
        label: String,
        isProbablyBlank: Bool,
        iosurfaceWidthPx: Int,
        iosurfaceHeightPx: Int,
        expectedWidthPx: Int,
        expectedHeightPx: Int,
        layerContentsGravity: String,
        isStretchRisk: Bool,
        layerContentsKey: String
    ) {
        self.label = label
        self.isProbablyBlank = isProbablyBlank
        self.iosurfaceWidthPx = iosurfaceWidthPx
        self.iosurfaceHeightPx = iosurfaceHeightPx
        self.expectedWidthPx = expectedWidthPx
        self.expectedHeightPx = expectedHeightPx
        self.layerContentsGravity = layerContentsGravity
        self.isStretchRisk = isStretchRisk
        self.layerContentsKey = layerContentsKey
    }
}
