/// Validates that a terminal replay was captured after the host applied the
/// viewport accepted for the requesting client.
public enum MobileTerminalReplayViewportFence {
    /// Legacy replay requests do not carry a viewport and remain accepted.
    /// Viewport-aware requests are accepted only when both cell dimensions
    /// exactly match the effective grid chosen by the host.
    public static func accepts(
        capturedColumns: Int,
        capturedRows: Int,
        expectedColumns: Int?,
        expectedRows: Int?
    ) -> Bool {
        guard let expectedColumns, let expectedRows else { return true }
        return capturedColumns == expectedColumns && capturedRows == expectedRows
    }
}
