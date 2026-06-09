internal import CMUXMobileCore

/// Per-frame metadata for the terminal view (Stage 1 local scroll). Carries
/// only the active screen and, for a full snapshot, the scrollback rows it
/// flowed into the local surface. Never content; the byte stream owns content.
public struct MobileTerminalFrameMeta: Sendable {
    /// Whether the active screen is the alternate screen (TUI). Primary
    /// scrolls locally; alternate forwards to the Mac.
    public let isAlternateScreen: Bool
    /// Whether this was a full snapshot (it rebuilt the local surface at the
    /// live bottom and flowed `scrollbackRows` of history).
    public let isFullSnapshot: Bool
    /// Scrollback rows flowed into the local surface by a full snapshot.
    /// Zero for a delta (a delta grows no local history).
    public let scrollbackRows: Int
}

/// Owns the per-surface frame-metadata streams the composite fans render-grid
/// frames into. Metadata rides a separate `AsyncStream` from the opaque VT
/// byte stream (which stays a pure content channel); the two are consumed by
/// the same view coordinator and share the byte stream's lifetime. Cross-stream
/// ordering is NOT guaranteed and nothing may rely on it: the snap-to-live
/// decision is made by the view per applied byte chunk from its own scroll
/// state, and the active-screen gate self-heals on the next frame if a flip's
/// meta lands late.
@MainActor
final class MobileTerminalFrameMetaHub {
    private var continuationsBySurfaceID: [String: AsyncStream<MobileTerminalFrameMeta>.Continuation] = [:]

    /// The per-frame metadata stream for a terminal surface (active screen +
    /// full-snapshot scrollback depth).
    func stream(surfaceID: String) -> AsyncStream<MobileTerminalFrameMeta> {
        AsyncStream { continuation in
            continuationsBySurfaceID[surfaceID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.continuationsBySurfaceID.removeValue(forKey: surfaceID)
                }
            }
        }
    }

    /// Yield one frame's metadata to the surface's stream, if one is attached.
    func deliver(from frame: MobileTerminalRenderGridFrame) {
        let meta = MobileTerminalFrameMeta(
            isAlternateScreen: frame.activeScreen == .alternate,
            isFullSnapshot: frame.full,
            scrollbackRows: frame.full ? frame.scrollbackRows : 0
        )
        continuationsBySurfaceID[frame.surfaceID]?.yield(meta)
    }

    /// Finish and drop a surface's stream. Called from byte-stream teardown so
    /// it cannot leave a dangling meta continuation (the stream's own
    /// onTermination also cleans up; this is the symmetric path).
    func finish(surfaceID: String) {
        continuationsBySurfaceID.removeValue(forKey: surfaceID)?.finish()
    }
}
