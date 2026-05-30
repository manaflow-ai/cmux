/// Subscription mode for the SSE output stream.
///
/// - ``raw``: live PTY byte increments (ghostty patch #2, Phase 2). No
///   replay of bytes consumed before subscription.
/// - ``cells``: throttled full ``CellGrid`` snapshots, emitted only when
///   the surface is dirty since the last tick (D8 — polled FNV-1a hash,
///   default 5 Hz; no third ghostty patch).
public enum StreamMode: String, Sendable, Codable, Hashable {
    /// Live PTY byte increments emitted as they arrive.
    case raw
    /// Throttled full-grid snapshots emitted when the surface is dirty.
    case cells
}
