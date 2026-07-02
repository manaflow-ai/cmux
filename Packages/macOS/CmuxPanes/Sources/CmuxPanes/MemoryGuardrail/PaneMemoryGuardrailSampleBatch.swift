/// A batch of pane-memory samples from one guardrail scan.
public struct PaneMemoryGuardrailSampleBatch: Sendable {
    /// Samples for the normal per-pane attribution path.
    public let samples: [PaneMemorySample]
    /// Extra CMUX-scoped samples keyed by pane, used to bridge cheaper scans.
    public let scopedOnlySamplesByKey: [PaneMemoryPaneKey: PaneMemorySample]
    /// Whether the batch was captured with CMUX process-scope attribution.
    public let includesCMUXScope: Bool

    /// Creates a sample batch.
    ///
    /// - Parameters:
    ///   - samples: Normal per-pane samples for this scan.
    ///   - scopedOnlySamplesByKey: CMUX-scope-only samples keyed by pane.
    ///   - includesCMUXScope: Whether the scan included CMUX process scope.
    public init(
        samples: [PaneMemorySample],
        scopedOnlySamplesByKey: [PaneMemoryPaneKey: PaneMemorySample],
        includesCMUXScope: Bool
    ) {
        self.samples = samples
        self.scopedOnlySamplesByKey = scopedOnlySamplesByKey
        self.includesCMUXScope = includesCMUXScope
    }
}
