import AppKit
import CmuxSettingsUI
import CmuxShortcuts
import CmuxWindowing

/// Conforms ``AppDelegate`` to the `CmuxShortcuts` routing seams so the
/// package's ``ShortcutRouter`` can drive shortcut routing while the parts that
/// touch live `TabManager`/`Workspace`/browser/command-palette state and the
/// app's `KeyboardShortcutSettings.Action` catalog stay app-side.
///
/// The router owns the relocated cluster state (the per-event focus-context
/// cache) and the chord/decode lifecycle. This conformance supplies the
/// irreducibly app-coupled collaborators:
///
/// - ``ShortcutWindowRouting`` — `shortcutRoutingKeyWindow` / `shortcutRoutingActiveWindow`
///   already exist in `AppDelegate+ShortcutRoutingWindow.swift`; this adds the
///   per-event chord window number and the active-context synchronization, both
///   of which mutate `AppDelegate`'s own stored window state.
/// - ``FocusContextReading`` — `resolveFocusSnapshot(for:)` lives in
///   `KeyboardShortcutContext.swift`, projecting the live focus context onto the
///   value snapshot the router caches.
/// - ``ShortcutRoutingHost`` — the recorder-standdown flag and the full
///   configured-shortcut dispatch (`handleCustomShortcut`), which evaluates the
///   action catalog and performs the matched action against live god state.
extension AppDelegate: ShortcutRoutingHost {
    func chordWindowNumber(for event: NSEvent) -> Int? {
        configuredShortcutChordWindowNumber(for: event)
    }

    @discardableResult
    func synchronizeRoutingContext(for event: NSEvent) -> Bool {
        synchronizeShortcutRoutingContext(event: event)
    }

    var isAnyShortcutRecorderActive: Bool {
        KeyboardShortcutRecorderActivity.isAnyRecorderActive || RecorderHostButton.isActivelyRecording
    }

    func dispatchConfiguredShortcut(event: NSEvent) -> Bool {
        // The irreducibly app-coupled configured-shortcut dispatch: it evaluates
        // the `KeyboardShortcutSettings.Action` catalog and performs the matched
        // action against live `TabManager`/`Workspace`/browser/command-palette
        // state, none of which can cross into `CmuxShortcuts`. The router has
        // already run the keyDown/recorder/chord/focus-cache lifecycle, so this
        // body only does the catalog match. Every former direct caller of
        // `handleCustomShortcut` (the local monitor, the AppKit key-equivalent
        // handlers, the debug hooks) now reaches it through
        // `shortcutRouter.handle(event:)`.
        dispatchConfiguredShortcutBody(event: event)
    }

    func dispatchPopupCloseShortcut(event: NSEvent, popupWindow: NSWindow) -> Bool {
        // The irreducibly app-coupled browser-popup close dispatch: it matches
        // the close-tab shortcut against the live popup window controller. The
        // router has already run the shared lifecycle, so this body only does the
        // close-tab match and chord arming.
        dispatchPopupCloseShortcutBody(event: event, popupWindow: popupWindow)
    }

    func clearLiveFocusCache(for event: NSEvent) {
        clearLiveShortcutEventFocusContextCache(for: event)
    }
}

/// Adapts the app's existing `ShortcutChordCoordinator<ShortcutStroke>` (in
/// `CmuxWindowing`) to the package's non-generic ``ShortcutChordControlling``
/// per-event lifecycle seam, so `CmuxShortcuts` does not depend on
/// `CmuxWindowing`.
@MainActor
final class AppDelegateShortcutChordAdapter: ShortcutChordControlling {
    private let coordinator: ShortcutChordCoordinator<ShortcutStroke>

    init(coordinator: ShortcutChordCoordinator<ShortcutStroke>) {
        self.coordinator = coordinator
    }

    func clear() {
        coordinator.clear()
    }

    func prepareForEvent(windowNumber: Int?) {
        coordinator.prepareForEvent(windowNumber: windowNumber)
    }

    func clearActivePrefixForCurrentEvent() {
        coordinator.activePrefixForCurrentEvent = nil
    }
}
