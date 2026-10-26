public import AppKit

/// The app's file picker, made ahead of the click: Home's "+" and an agent composer's
/// + > Attach files or images (a page's `<input type="file">`) take this panel.
///
/// `NSOpenPanel()` costs 105 to 120 ms on the main thread, about 300 ms for the process's
/// first one (frameworks and the panel service load), before `beginSheetModal` adds its own
/// 270 ms. Bench on a capture mini (macOS 26.3.1, a bare app, 2026-10-21): a new panel per
/// click first shows its sheet 830 ms after the click in a fresh process and 160 ms after it
/// later; the panel made ahead shows it after 95 ms, then 45 to 65 ms. One panel is made while
/// the person is idle and reused. The warm-up still costs that main-thread time once, at a
/// pause or while cmux is in the background, and it has no deadline: AppKit makes the panel only
/// on the main thread and cannot ask its view service first, so with a hung panel service the
/// warm-up (or a click with no panel made ahead) blocks the main thread once, up to about 40 s,
/// before the dead panel stops further warm-ups. The logic is ``MadeAheadPanelStore``'s; when
/// the warm-up may run is ``OpenPanelWarmGate``'s.
///
/// The app makes one, at its composition root (`AppServices.openPanel`), and passes it to every picker that takes
/// it: `AgentPaneView` (and its `AgentPaneFilePicker`), Home's `HomeAttachmentPanel`, and a WebKit view's
/// `<input type="file">` (``WebFileInputAnswering``: `PageOpenPanel` for a cmux page on WebKit, and the WebKit
/// browser engine's `fileInput`). Chromium does not take it: a Chromium browser tab or a cmux page hosted in
/// Chromium (the default engine) has no file-dialog handler in the CEF shim, so Chromium makes its own new
/// `NSOpenPanel` on the main thread for each click, not made ahead and with no dead-panel guard (open, routed to
/// the CEF owners). Each instance keeps its own panel, so a test makes its own and never shares one with the app.
@MainActor
public final class MadeAheadOpenPanel {
    private let store: MadeAheadPanelStore<NSOpenPanel>

    /// Whether the panel was made ahead of a click.
    public var isMade: Bool { store.isMade }
    /// The warm-up checks run so far.
    public var warmChecks: Int { store.warmChecks }
    /// Whether a warm-up check is pending.
    public var isWarming: Bool { store.isWarming }

    public init() {
        let gate = OpenPanelWarmGate()
        store = MadeAheadPanelStore(makePanel: { NSOpenPanel() }, warmCheck: { gate.check() })
    }

    /// The panel made ahead when it is free (no sheet or window shows it), else a new one (it
    /// shows on another window). Either comes as a new panel would: one file, no folders, every
    /// type, the system's prompt and no message; the caller sets what it needs.
    ///
    /// - Returns: nil when the new panel came back dead (no prompt: its view service never
    ///   answered, no GUI session). The caller shows no picker: a dead panel's sheet may never
    ///   call its handler, and a caller that waits on it would wait forever.
    public func panel() -> NSOpenPanel? { store.panel() }

    /// Makes the panel once the person has paused (no input for a second), so its cost never
    /// lands on a keystroke or the click itself. Bounded: after ten busy checks it waits for the
    /// click. A view that offers the picker calls this when it reaches a window.
    public func warmWhenIdle() { store.warmWhenIdle() }

    /// Starts ``warmWhenIdle()`` when `schedule` runs its work: the app passes its launch's first idle moment
    /// (`LaunchSettle.whenSettled`), so the first click on a picker is not cold even before a view that offers it
    /// reached a window (Lead decision 2026-10-23: keep the system panel; start its warm-up at launch idle).
    ///
    /// - Parameter schedule: runs the work it is given once, later or at once (for example after the first frame).
    ///
    /// ```swift
    /// services.openPanel.warmWhenIdle(after: launchSettle.whenSettled)
    /// ```
    public func warmWhenIdle(after schedule: (@escaping @MainActor () -> Void) -> Void) {
        schedule { [weak self] in self?.warmWhenIdle() }
    }
}
