public import AppKit

/// Owns the configured-shortcut routing lifecycle that used to live as ~80
/// methods and a dozen stored properties on the `AppDelegate` god object.
///
/// ## Responsibility
///
/// This is the orchestration owner for turning a routed keyboard ``NSEvent``
/// into a consumed-or-passed-through decision. It owns the parts of the former
/// `AppDelegate` shortcut cluster that do not require live `TabManager`/
/// `Workspace`/browser/command-palette state or the app's
/// `KeyboardShortcutSettings.Action` catalog:
///
/// - the per-event **focus-context cache** (relocated from
///   `AppDelegate.shortcutEventFocusContextCache`), so a single event resolves
///   its focus snapshot at most once;
/// - the **chord lifecycle** clears around each dispatched event (it delegates
///   the chord state machine to the injected ``ShortcutChordControlling``
///   collaborator, which already lives in its own package);
/// - the **decode** the matchers need, through the held ``ShortcutEventDecoding``
///   seam (``ShortcutCoordinator``).
///
/// Everything that touches live god state stays app-side behind
/// ``ShortcutRoutingHost``: the actual configured-shortcut dispatch, the window
/// routing (``ShortcutWindowRouting``), and the focus-snapshot resolution
/// (``FocusContextReading``). The router reaches all of it through one held
/// `host` reference.
///
/// ## Isolation
///
/// `@MainActor` because every caller (the local key-event monitor, the AppKit
/// `cmux_sendEvent`/`cmux_performKeyEquivalent` swizzles, the menu suppressor)
/// runs on the main thread. State co-locates with its callers, so the keystroke
/// hot path takes plain property access and no cross-actor bridge (the same
/// ruling as ``ShortcutCoordinator`` and ``ShortcutChordCoordinator``).
///
/// ## Latency
///
/// `handle(event:)` is on the keystroke hot path (the local key-event monitor,
/// the AppKit `cmux_sendEvent`/`cmux_performKeyEquivalent` swizzle forwarders,
/// and the debug hooks all reach it). It does one keyDown guard, one
/// recorder-standdown check, prepares the chord prefix for the event, calls the
/// host's dispatch, then clears the per-event chord prefix and both focus caches
/// (its own value-snapshot cache plus the host's live cache) in a `defer`. The
/// keyDown/recorder/chord/focus-cache lifecycle is shared with
/// `handle(popupCloseEvent:popupWindow:)` through `routeWithLifecycle`, so both
/// entry points run identical setup/teardown. No per-event allocation beyond
/// what the legacy `handleCustomShortcut` prelude already performed.
@MainActor
public final class ShortcutRouter: ShortcutRouting {
    /// The app-side collaborator the router drives for everything that touches
    /// live god state (window routing, focus-snapshot resolution, and the
    /// configured-shortcut dispatch itself).
    private let host: any ShortcutRoutingHost

    /// The chord (two-stroke prefix) state machine. Injected because it already
    /// lives in its own package (`CmuxWindowing.ShortcutChordCoordinator`); the
    /// router only drives its per-event lifecycle.
    private let chord: any ShortcutChordControlling

    /// The per-event focus-context cache, relocated from
    /// `AppDelegate.shortcutEventFocusContextCache`. Keyed by event identity so a
    /// single dispatched event resolves its focus snapshot at most once. Cleared
    /// in the `handle(event:)` `defer` for the event it was populated for.
    private var focusContextCache: (event: NSEvent, snapshot: ShortcutEventFocusSnapshot)?

    /// Creates a router driving `host`, using `chord` for the two-stroke prefix
    /// lifecycle.
    ///
    /// - Parameters:
    ///   - host: The app-side conformer that performs the configured-shortcut
    ///     dispatch and exposes the live window/focus seams.
    ///   - chord: The chord state machine (the app injects its existing
    ///     `CmuxWindowing.ShortcutChordCoordinator`).
    public init(host: any ShortcutRoutingHost, chord: any ShortcutChordControlling) {
        self.host = host
        self.chord = chord
    }

    public func handle(event: NSEvent) -> Bool {
        routeWithLifecycle(event: event) { host, event in
            host.dispatchConfiguredShortcut(event: event)
        }
    }

    public func handle(popupCloseEvent event: NSEvent, popupWindow: NSWindow) -> Bool {
        routeWithLifecycle(event: event) { host, event in
            host.dispatchPopupCloseShortcut(event: event, popupWindow: popupWindow)
        }
    }

    /// Runs the shared per-event routing lifecycle (the keyDown guard, the
    /// recorder standdown, the chord prepare, and the end-of-turn chord-prefix +
    /// focus-cache teardown) around `dispatch`. This is the single relocation of
    /// the prelude/`defer` that the former `handleCustomShortcut` and
    /// `handleBrowserPopupCloseShortcutKeyEquivalent` each duplicated; both
    /// dispatch bodies now run only their catalog/close match.
    private func routeWithLifecycle(
        event: NSEvent,
        _ dispatch: (any ShortcutRoutingHost, NSEvent) -> Bool
    ) -> Bool {
        guard event.type == .keyDown else {
            chord.clear()
            return false
        }
        // A recorder being armed must suppress every app-level shortcut so the
        // keystroke reaches it to be rebound (issue #5189). Relocated from the
        // top of the former `handleCustomShortcut`.
        guard !host.isAnyShortcutRecorderActive else {
            chord.clear()
            return false
        }

        chord.prepareForEvent(windowNumber: host.chordWindowNumber(for: event))
        defer {
            chord.clearActivePrefixForCurrentEvent()
            clearFocusSnapshotCache(for: event)
            host.clearLiveFocusCache(for: event)
        }

        return dispatch(host, event)
    }

    /// The focus snapshot for `event`, resolving and caching it through the host
    /// on first read for an event and returning the cached value afterward.
    /// Faithful relocation of `AppDelegate.shortcutEventFocusContext(_:)`'s cache
    /// behavior; the resolution itself stays app-side via ``FocusContextReading``.
    public func focusSnapshot(for event: NSEvent) -> ShortcutEventFocusSnapshot {
        if let cache = focusContextCache, cache.event === event {
            return cache.snapshot
        }
        let snapshot = host.resolveFocusSnapshot(for: event)
        focusContextCache = (event, snapshot)
        return snapshot
    }

    /// Drops the cached focus snapshot if it belongs to `event`. Faithful
    /// relocation of `AppDelegate.clearShortcutEventFocusContextCache(for:)`.
    public func clearFocusSnapshotCache(for event: NSEvent) {
        if focusContextCache?.event === event {
            focusContextCache = nil
        }
    }

    /// Unconditionally drops the cached focus snapshot. Used by the app's
    /// shortcut-routing test-reset path (the former
    /// `shortcutEventFocusContextCache = nil` assignments) so a test can force
    /// the next event to re-resolve its focus snapshot.
    public func resetFocusSnapshotCache() {
        focusContextCache = nil
    }
}
