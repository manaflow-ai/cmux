/// A hidden terminal lets its Ghostty surface go (p01-process-140, feature `terminalHiddenSurfaceRelease`):
/// after ``grace`` hidden, the session frees the surface (its renderer and IO threads, font atlases, GPU
/// buffers and VT mirror) and keeps only its last presented frame, volatile. The attach stream stays open,
/// so its offset is kept; output while released is not parsed. Shown again, a fresh surface is built in
/// the show's turn, the last frame stays painted over it, and the PTY owner's READY (a `snapshot-request`)
/// plus the stream's tail after it rebuild the screen in one layout.
///
/// Chrome does the same with a hidden view's compositor frame: `FrameEvictor` drops it after the view is
/// hidden (components/viz/client/frame_evictor.cc), and a view shown again embeds its fallback surface
/// until the renderer submits a new frame (content/browser/renderer_host/delegated_frame_host.cc,
/// `DelegatedFrameHost::EvictDelegatedFrame` and `WasShown`).
public nonisolated struct TerminalSurfaceRelease: Sendable, Equatable {
    /// How long a terminal stays hidden before its surface goes.
    public static let defaultGrace: Duration = .seconds(30)

    public var grace: Duration

    public init(grace: Duration = defaultGrace) {
        self.grace = grace
    }
}

/// Whether a session's surface is live, waiting out its hidden grace, or released, and what a change of
/// its inputs does (``TerminalSurfaceRelease``). Pure, so its rules are tested without a surface.
nonisolated struct TerminalSurfaceDormancy: Equatable {
    enum State: Equatable {
        case live
        /// Hidden and releasable: the grace runs.
        case waiting
        /// The surface is freed until the terminal shows again.
        case released
    }

    struct Inputs: Equatable {
        /// Rendering suspended and no mirror draws it.
        var hidden: Bool
        /// The owner keeps the VT state and can answer a resync with a READY, and the stream is live.
        var rebuildable: Bool
        /// State only the surface holds would be lost (a pinned copy-mode selection).
        var pinned: Bool

        var releasable: Bool { hidden && rebuildable && !pinned }
    }

    enum Step: Equatable {
        case none
        case startGrace
        case cancelGrace
        case release
        case rebuild
    }

    private(set) var state = State.live

    /// The inputs changed.
    mutating func update(_ inputs: Inputs) -> Step {
        switch state {
        case .live:
            guard inputs.releasable else { return .none }
            state = .waiting
            return .startGrace
        case .waiting:
            guard !inputs.releasable else { return .none }
            state = .live
            return .cancelGrace
        case .released:
            // A released surface stays released while hidden, whatever its stream does meanwhile.
            guard !inputs.hidden else { return .none }
            state = .live
            return .rebuild
        }
    }

    /// The grace ended: release when still waiting and releasable.
    mutating func graceEnded(_ inputs: Inputs) -> Step {
        guard state == .waiting else { return .none }
        guard inputs.releasable else {
            state = .live
            return .none
        }
        state = .released
        return .release
    }
}
