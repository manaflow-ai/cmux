/// The narrow per-event lifecycle seam ``ShortcutRouter`` drives the chord
/// (two-stroke prefix) state machine through.
///
/// ## Why this seam exists
///
/// The chord state machine already lives in its own package
/// (`CmuxWindowing.ShortcutChordCoordinator`), which is generic over the app's
/// `ShortcutStroke` type and accepts the match predicate as a closure. The
/// router only needs to drive that machine's per-event lifecycle (clear it,
/// prepare the prefix for an event, drop the active prefix at end of turn); it
/// does not need the generic stroke type or the arm/match logic, which stay with
/// the app-side dispatch that owns the stroke matching.
///
/// Routing this through a non-generic protocol keeps `CmuxShortcuts` free of a
/// dependency on `CmuxWindowing` (no DAG edge between two macOS domain
/// packages). The app composition root adapts its existing
/// `ShortcutChordCoordinator<ShortcutStroke>` instance to this protocol.
///
/// ## Isolation
///
/// `@MainActor` to match the chord coordinator and the keystroke hot path.
@MainActor
public protocol ShortcutChordControlling: AnyObject {
    /// Clears all chord state (drops any pending prefix and the active prefix).
    /// Faithful relocation of the legacy `clearConfiguredShortcutChordState()`.
    func clear()

    /// Begins a dispatch turn for an event originating in `windowNumber`,
    /// activating a pending same-window prefix. Forwards to
    /// `ShortcutChordCoordinator.prepareForEvent(windowNumber:)`.
    func prepareForEvent(windowNumber: Int?)

    /// Resets the prefix that is live for the current event to `nil` at the end
    /// of the dispatch turn. Maps to setting
    /// `ShortcutChordCoordinator.activePrefixForCurrentEvent = nil`, the reset the
    /// former `handleCustomShortcut` ran in its `defer`.
    func clearActivePrefixForCurrentEvent()
}
