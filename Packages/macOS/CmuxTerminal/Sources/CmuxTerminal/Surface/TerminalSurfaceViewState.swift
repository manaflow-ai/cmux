public import Observation

/// The Observation-tracked view state for one terminal surface.
///
/// This facade is the only surface state SwiftUI and `withObservationTracking`
/// mirrors react to. `TerminalSurface` itself is a plain runtime class whose
/// bookkeeping (surface pointer, renderer/portal lifecycle, IO buffers, size
/// caches) is deliberately untracked: it is read and written from
/// `NSViewRepresentable` update paths, and tracking it re-dirties the SwiftUI
/// view graph on every representable update (the 100%-CPU spin class).
/// Keeping the tracked set in a dedicated type makes that partition hold by
/// construction: a new stored property on `TerminalSurface` is untracked
/// unless it is consciously moved here.
@Observable
public final class TerminalSurfaceViewState {
    /// The live find-in-terminal session state, when the find bar is open.
    public internal(set) var searchState: TerminalSurface.SearchState?

    /// Whether keyboard copy mode is active (mirrors the surface view).
    public internal(set) var keyboardCopyModeActive: Bool = false

    init() {}
}
