/// Bounds consecutive config-theme-mismatch resets for one mounted terminal
/// output consumer.
///
/// A theme-carrying chunk whose config theme no longer matches the store's
/// newest for its surface is normally abandoned (reset plus authoritative
/// replay) so the fresh replay repaints with the new theme. That is correct
/// for a genuine one-off theme change, but a producer that keeps alternating
/// between two resolved config themes re-mismatches every replayed frame, and
/// unbounded resets become a 5-10Hz replay storm that saturates the main
/// actor until the watchdog kills the app (CMUXTERM-MACOS-3CX6, 3D1S, 3D6T,
/// 3DFD). Past the bound the consumer applies the chunk with its own carried
/// config theme instead — `processOutputAndWait(_:terminalConfigTheme:)`
/// installs that theme atomically with the bytes on the surface's serial
/// Ghostty queue, so the paint stays self-consistent and converges to the
/// newest theme as the queue drains. A matching theme-carrying chunk re-arms
/// the reset budget.
public struct TerminalConfigThemeMismatchResetPolicy: Sendable {
    private var consecutiveResets = 0
    private let maxConsecutiveResets: Int

    /// - Parameter maxConsecutiveResets: Mismatch resets allowed in a row
    ///   before mismatched chunks apply with their carried theme instead.
    public init(maxConsecutiveResets: Int = 3) {
        self.maxConsecutiveResets = maxConsecutiveResets
    }

    /// Records one theme-carrying chunk's match outcome and returns whether
    /// the consumer must reset-and-replay for it.
    /// - Parameter chunkMatchesStoreTheme: Whether the chunk's carried config
    ///   theme equals the store's newest config theme for the surface.
    /// - Returns: `true` to abandon the chunk (reset plus replay); `false` to
    ///   apply it with its own carried config theme.
    public mutating func shouldReset(chunkMatchesStoreTheme: Bool) -> Bool {
        guard !chunkMatchesStoreTheme else {
            consecutiveResets = 0
            return false
        }
        guard consecutiveResets < maxConsecutiveResets else { return false }
        consecutiveResets += 1
        return true
    }
}
