public import AppKit

/// The composite collaborator seam ``ShortcutRouter`` calls down through to
/// perform the parts of configured-shortcut dispatch that touch live app state
/// it does not own.
///
/// ## Why this seam exists
///
/// The configured-shortcut dispatch (`handleCustomShortcut` and its
/// split/browser/group/quit/menu-suppression bodies) reaches the app's
/// `TabManager`, `Workspace`, `BrowserPanel`, `MarkdownPanel`, command palette,
/// and per-window routing state. Those types are owned by other slices
/// (workspace, terminal, browser, sidebar, command palette) and the app's
/// `KeyboardShortcutSettings.Action` catalog is owned by the settings slice.
/// None of them can cross into this package, so the dispatch that *consumes*
/// them stays app-side as the host conformer, and ``ShortcutRouter`` drives it
/// through this protocol.
///
/// This composes the two read seams the routing needs (``ShortcutWindowRouting`` for
/// the live window/route state and ``FocusContextReading`` for the per-event
/// focus snapshot) and adds the small set of side-effecting actions the matched
/// dispatch performs. As the workspace/terminal/browser/catalog slices land
/// their own seams, the action members here are the integration points that move
/// onto those slices' protocols; until then the app target conforms with one
/// `AppDelegate` extension that forwards to the existing bodies.
///
/// ## Latency
///
/// `handle(event:)` is on the keystroke hot path. The router holds one
/// reference to its host and reads ``ShortcutWindowRouting``/``FocusContextReading``
/// members directly; no per-event allocation crosses this seam.
@MainActor
public protocol ShortcutRoutingHost: ShortcutWindowRouting, FocusContextReading {
    /// Whether any shortcut recorder (legacy in-app or the Settings UI recorder)
    /// is armed, in which case routing must stand down so the keystroke reaches
    /// the recorder. Faithful relocation of the
    /// `KeyboardShortcutRecorderActivity.isAnyRecorderActive || RecorderHostButton.isActivelyRecording`
    /// guard at the top of `handleCustomShortcut`.
    var isAnyShortcutRecorderActive: Bool { get }

    /// Runs the full app-side configured-shortcut dispatch for `event`, returning
    /// `true` when it consumed the event. This is the irreducibly app-coupled
    /// body of the former `AppDelegate.handleCustomShortcut(event:)`: it reads the
    /// focus snapshot (via ``FocusContextReading``), evaluates the app's
    /// `KeyboardShortcutSettings.Action` catalog, and performs the matched action
    /// against live `TabManager`/`Workspace`/browser/command-palette state. It is
    /// reached through the seam (rather than inlined into the router) because
    /// every type it touches is owned by another slice; the router owns the
    /// recorder-standdown guard, the chord lifecycle, and the focus-cache
    /// lifetime around it.
    ///
    /// The body must NOT re-run the keyDown/recorder/chord/focus-cache lifecycle:
    /// ``ShortcutRouter/handle(event:)`` already performed it before calling this.
    func dispatchConfiguredShortcut(event: NSEvent) -> Bool

    /// Runs the app-side browser-popup close-shortcut dispatch for `event`
    /// targeting `popupWindow`, returning `true` when it consumed the event.
    /// Same lifecycle contract as ``dispatchConfiguredShortcut(event:)``: the
    /// router owns the keyDown/recorder/chord/focus-cache lifecycle and this body
    /// only evaluates the close-tab match against `popupWindow`. Irreducibly
    /// app-coupled because it reaches the live browser popup window controller.
    func dispatchPopupCloseShortcut(event: NSEvent, popupWindow: NSWindow) -> Bool

    /// Drops the app-side live focus context (the cache that still carries the
    /// `BrowserPanel`/`MarkdownPanel` references the dispatch acts on, which
    /// cannot cross the module boundary) for `event`. Called from the router's
    /// per-event `defer` alongside the router's own value-snapshot cache clear so
    /// both caches share one lifetime keyed on event identity.
    func clearLiveFocusCache(for event: NSEvent)
}
