public import AppKit

/// A bounded collection of browser screenshot probes for one viewport state.
public struct BrowserScreenshotProbeSet: Equatable, Sendable {
    /// CSS viewport size with a top-left origin.
    public let viewportSize: NSSize
    /// Candidate text probes distributed across the viewport.
    public let probes: [BrowserScreenshotProbe]

    /// Creates a probe set for a viewport state.
    ///
    /// - Parameters:
    ///   - viewportSize: CSS viewport size represented by the probes.
    ///   - probes: Bounded text probes distributed across the viewport.
    public init(viewportSize: NSSize, probes: [BrowserScreenshotProbe]) {
        self.viewportSize = viewportSize
        self.probes = probes
    }
}
