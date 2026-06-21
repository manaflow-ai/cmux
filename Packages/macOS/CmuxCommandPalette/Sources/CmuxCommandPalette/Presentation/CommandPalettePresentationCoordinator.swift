public import Foundation
public import Observation

/// `@MainActor @Observable` owner of the per-window command-palette request,
/// visibility, escape-suppression, selection, and snapshot state machine.
///
/// This is the seam the app target's command-palette glue forwards through. The
/// app target resolves `NSWindow` values to `WindowID`s (`UUID`) and reads the
/// live `NSResponder`/overlay hierarchy; everything window-agnostic — the
/// pending-open grace/prune timing, escape-suppression timing, the visibility
/// state transitions, and the request-dispatch policy — lives here on top of the
/// owned ``CommandPaletteWindowStore``.
///
/// ## Isolation
///
/// Every mutator runs on the main actor: shortcut routing, SwiftUI visibility
/// sync, and socket-driven simulation all hop to main before touching palette
/// state. So the coordinator is `@MainActor` and co-locates its state with its
/// callers; there is no actor hop and no lock. It does no I/O itself — the three
/// app-coupled effects (notification posting, browser-focus clearing, DEBUG
/// logging) are injected as ``CommandPalettePresentationEffects`` closures.
///
/// ## Timing
///
/// Wall-clock reads go through the injected ``now`` provider (default
/// `ProcessInfo.processInfo.systemUptime`, the same source the inline app-target
/// code used) so the timing logic stays testable with a manual clock.
@MainActor
@Observable
public final class CommandPalettePresentationCoordinator {
    /// The per-window state store this coordinator owns and drives.
    @ObservationIgnored public let store: CommandPaletteWindowStore

    @ObservationIgnored private let effects: CommandPalettePresentationEffects
    @ObservationIgnored private let now: @MainActor () -> TimeInterval

    /// Creates a coordinator.
    ///
    /// - Parameters:
    ///   - store: the per-window state store (a fresh one by default).
    ///   - effects: the app-coupled side effects (`.noop` for pure tests).
    ///   - now: the wall-clock provider; defaults to `systemUptime`.
    public init(
        store: CommandPaletteWindowStore = CommandPaletteWindowStore(),
        effects: CommandPalettePresentationEffects,
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.store = store
        self.effects = effects
        self.now = now
    }

    // MARK: Registration / teardown

    /// Seeds baseline palette state for a newly registered window.
    public func registerWindow(_ windowId: UUID) {
        store.registerWindow(windowId)
    }

    /// Removes every piece of palette state for a window being torn down.
    public func removeWindow(_ windowId: UUID) {
        store.removeWindow(windowId)
    }

    // MARK: Pending-open

    /// Marks a window as having requested a palette open at the current time.
    public func markOpenRequested(_ windowId: UUID) {
        store.markOpenRequested(windowId, now: now())
    }

    /// Clears the pending-open request for a window.
    public func clearPendingOpen(_ windowId: UUID) {
        store.clearPendingOpen(windowId)
    }

    /// Prunes stale pending-open entries, emitting the same DEBUG diagnostics the
    /// inline app-target code did.
    public func pruneExpiredPendingOpenStates() {
        let pruned = store.pruneExpiredPendingOpenStates(now: now())
#if DEBUG
        for outcome in pruned {
            switch outcome {
            case .missingTimestamp(let windowId):
                effects.log("shortcut.palette.pendingPrune windowId=\(windowId.uuidString.prefix(8)) reason=missingTimestamp")
            case .stale(let windowId, let age):
                effects.log(
                    "shortcut.palette.pendingPrune windowId=\(windowId.uuidString.prefix(8)) " +
                    "reason=stale ageMs=\(Int(age * 1000))"
                )
            }
        }
#else
        _ = pruned
#endif
    }

    /// Whether a window has a live pending-open request after pruning stale entries.
    public func isPendingOpen(_ windowId: UUID) -> Bool {
        pruneExpiredPendingOpenStates()
        return store.isPendingOpenRaw(windowId)
    }

    /// The age of a recent, still-fresh palette request, or `nil` when none applies.
    public func recentRequestAge(_ windowId: UUID) -> TimeInterval? {
        store.recentRequestAge(windowId, now: now())
    }

    // MARK: Escape suppression

    /// Begins escape suppression for a window at the current time.
    public func beginEscapeSuppression(_ windowId: UUID) {
        store.beginEscapeSuppression(windowId, now: now())
    }

    /// Ends escape suppression for a window.
    public func endEscapeSuppression(_ windowId: UUID) {
        store.endEscapeSuppression(windowId)
    }

    /// Whether a suppressed escape should be consumed for a window at the current time.
    public func shouldConsumeSuppressedEscape(_ windowId: UUID) -> Bool {
        store.shouldConsumeSuppressedEscape(windowId, now: now())
    }

    /// Clears escape suppression for every window (fallback when no window resolves).
    public func clearAllEscapeSuppression() {
        store.clearAllEscapeSuppression()
    }

    // MARK: Request dispatch

    /// Dispatches a palette open request for `windowId`.
    ///
    /// Runs `clearBrowserFocusMode` (the app-target focus-mode clear, keyed off the
    /// live target `NSWindow`), marks the window pending-open when the kind requires
    /// it, runs `post` (the app-target notification post against the target window),
    /// and emits the request DEBUG diagnostic. `windowId` is `nil` when the target
    /// window has no resolvable identifier; in that case pending marking is skipped
    /// (matching the inline behavior), but `clearBrowserFocusMode` and `post` both
    /// still run because they key off the `NSWindow`, not its id.
    public func postRequest(
        kind: CommandPaletteRequestKind,
        windowId: UUID?,
        source: String,
        debugTarget: @autoclosure () -> String,
        clearBrowserFocusMode: @MainActor () -> Void,
        post: @MainActor () -> Void
    ) {
        clearBrowserFocusMode()
        let markPending = kind.marksPending
        if markPending, let windowId {
            markOpenRequested(windowId)
        }
        post()
#if DEBUG
        effects.log(
            "shortcut.palette.request source=\(source) " +
            "target={\(debugTarget())} " +
            "pendingMarked=\(markPending ? 1 : 0)"
        )
#endif
    }

    // MARK: Visibility

    /// Updates a window's visibility, running `clearBrowserFocusMode` (the app-target
    /// focus-mode clear) on open, running `postVisibilityDidChange` (the app-target
    /// notification post against the live `NSWindow`) when the value flips, and
    /// emitting the retain-pending DEBUG diagnostic.
    public func setVisible(
        _ visible: Bool,
        for windowId: UUID,
        debugWindow: @autoclosure () -> String,
        clearBrowserFocusMode: @MainActor () -> Void,
        postVisibilityDidChange: @MainActor (_ visible: Bool) -> Void
    ) {
        if visible {
            clearBrowserFocusMode()
        }
        // Opening (false -> true) always resolves pending-open.
        // Closing (true -> false) also clears stale pending state.
        // Ignore repeated false updates so a stale sync cannot erase an in-flight open request.
        let update = store.setVisible(visible, for: windowId)
        if update.wasVisible != visible {
            postVisibilityDidChange(visible)
        }
#if DEBUG
        if update.retainedPending {
            effects.log(
                "palette.visibility.retainPending " +
                "window={\(debugWindow())} visible=0 wasVisible=0 pending=1"
            )
        }
#endif
    }

    /// Whether the palette is marked visible for a window.
    public func isVisible(_ windowId: UUID) -> Bool {
        store.isVisible(windowId)
    }

    /// The first window id with the palette currently visible, if any.
    public func firstVisibleWindowId() -> UUID? {
        store.firstVisibleWindowId()
    }

    /// The first window id with a live pending-open request, if any.
    public func firstPendingOpenWindowId() -> UUID? {
        store.firstPendingOpenWindowId()
    }

    // MARK: Selection

    /// Sets the clamped selection index for a window.
    public func setSelectionIndex(_ index: Int, for windowId: UUID) {
        store.setSelectionIndex(index, for: windowId)
    }

    /// The selection index for a window, defaulting to zero.
    public func selectionIndex(_ windowId: UUID) -> Int {
        store.selectionIndex(windowId)
    }

    // MARK: Snapshot

    /// Stores the debug snapshot for a window.
    public func setSnapshot(_ snapshot: CommandPaletteDebugSnapshot, for windowId: UUID) {
        store.setSnapshot(snapshot, for: windowId)
    }

    /// The debug snapshot for a window, defaulting to empty.
    public func snapshot(_ windowId: UUID) -> CommandPaletteDebugSnapshot {
        store.snapshot(windowId)
    }

    // MARK: Test seams

    /// Forces a window's pending-open request to a given age (debug/test hook).
    public func setPendingOpenAge(_ windowId: UUID, age: TimeInterval) {
        store.setPendingOpenAge(windowId, now: now(), age: age)
    }
}
