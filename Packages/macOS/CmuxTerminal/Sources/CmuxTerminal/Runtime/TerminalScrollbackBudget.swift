/// Sets a logical per-surface scrollback cap for cmux's supported concurrency scale.
///
/// Ghostty's page allocation limit is heuristic. Active content, page rounding,
/// and complex graphemes can exceed the configured cap. The fixed per-surface
/// cap also scales linearly beyond `supportedSurfaceCount`.
struct TerminalScrollbackBudget: Equatable, Sendable {
    let targetAggregateScrollbackBytesAtSupportedScale: Int
    let supportedSurfaceCount: Int

    /// Keeps 64 saturated surfaces to 512 MiB and 128 surfaces to 1 GiB.
    static let cmuxDefault = TerminalScrollbackBudget(
        targetAggregateScrollbackBytesAtSupportedScale: 1_024 * 1_048_576,
        supportedSurfaceCount: 128
    )

    init(targetAggregateScrollbackBytesAtSupportedScale: Int, supportedSurfaceCount: Int) {
        precondition(targetAggregateScrollbackBytesAtSupportedScale > 0)
        precondition(supportedSurfaceCount > 0)
        self.targetAggregateScrollbackBytesAtSupportedScale = targetAggregateScrollbackBytesAtSupportedScale
        self.supportedSurfaceCount = supportedSurfaceCount
    }

    var maxBytesPerSurface: Int {
        targetAggregateScrollbackBytesAtSupportedScale / supportedSurfaceCount
    }

    func configuredCapBytes(surfaceCount: Int) -> Int {
        max(surfaceCount, 0) * maxBytesPerSurface
    }
}
