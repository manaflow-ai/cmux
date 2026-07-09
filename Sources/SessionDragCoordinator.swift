import Observation

/// Owns the "which section is currently being dragged" bit, separate from
/// `SessionIndexStore`. Isolating this means drag start/end does not invalidate
/// the data store's observers, so rows and gaps don't re-render every time a
/// drag begins or clears.
///
/// With `@Observable`, observation is field-granular: only views that actually
/// read `draggedKey` in their `body` (the parent `SessionIndexView`, which
/// snapshots it once per eval) re-render on a transition, never the data-store
/// subscribers.
@MainActor
@Observable
final class SessionDragCoordinator {
    var draggedKey: SectionKey? = nil
}
