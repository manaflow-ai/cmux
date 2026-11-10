public import AppKit

/// The app's file picker: Home's "+" and an agent composer's + > Attach files or images (a page's
/// `<input type="file">`) take their panel here. Each request gets a new `NSOpenPanel`, made at the request as
/// Chromium makes its file dialog's panel (`components/remote_cocoa/app_shim/select_file_dialog_bridge.mm`), and
/// the app keeps no panel at rest.
///
/// Why none is kept (2026-11-10): one panel used to be made while the person was idle and kept for the life of
/// the app, so a click paid only its sheet. But a live `NSOpenPanel` keeps its panel service
/// (`com.apple.appkit.xpc.openAndSavePanelService`) at work: the service syncs the folder the panel shows on each
/// file-system event (DesktopServicesPriv `TNode::SynchronizeChildren`), 2.8 to 4.8 % of a core for the life of
/// each app on a busy Mac. The numbers of both paths are in plans/cmux-next/picker.md.
///
/// What stays of the warm-up: `NSOpenPanel()` costs more for the process's first panel (about 300 ms on the main
/// thread: the frameworks load and the panel service answers for the first time) than for a later one (105 to
/// 120 ms). So the first panel of the process is made while the person is idle, at a pause or while cmux is in
/// the background, and let go at once. The warm-up has no deadline: AppKit makes the panel only on the main
/// thread and cannot ask its view service first, so with a hung panel service the warm-up (or a click) blocks
/// the main thread once, up to about 40 s, before the dead panel stops further warm-ups. The logic is
/// ``MadeAheadPanelStore``'s; when the warm-up may run is ``OpenPanelWarmGate``'s.
///
/// The app makes one, at its composition root (`AppServices.openPanel`), and passes it to every picker that takes
/// it: `AgentPaneView` (and its `AgentPaneFilePicker`), Home's `HomeAttachmentPanel`, and a WebKit view's
/// `<input type="file">` (``WebFileInputAnswering``: `PageOpenPanel` for a cmux page on WebKit, and the WebKit
/// browser engine's `fileInput`). Chromium does not take it: a Chromium browser tab or a cmux page hosted in
/// Chromium (the default engine) has no file-dialog handler in the CEF shim, so Chromium makes its own new
/// `NSOpenPanel` on the main thread for each click, with no dead-panel guard (open, routed to the CEF owners).
@MainActor
public final class MadeAheadOpenPanel {
    private let store: MadeAheadPanelStore<NSOpenPanel>

    /// Whether this process made a working panel (the warm-up's, or a click's): the first panel's cost is paid.
    public var isWarm: Bool { store.isWarm }
    /// The panels made here that are still alive: one per picker on screen, 0 at rest.
    public var livePanels: Int { store.livePanels }
    /// The warm-up checks run so far.
    public var warmChecks: Int { store.warmChecks }
    /// Whether a warm-up check is pending.
    public var isWarming: Bool { store.isWarming }

    public init() {
        let gate = OpenPanelWarmGate()
        store = MadeAheadPanelStore(makePanel: { NSOpenPanel() }, warmCheck: { gate.check() })
    }

    /// A new panel for this click, as AppKit makes it: one file, no folders, every type, the system's prompt and
    /// no message; the caller sets what it needs, shows it, and lets it go when its sheet ended.
    ///
    /// - Returns: nil when the new panel came back dead (no prompt: its view service never
    ///   answered, no GUI session). The caller shows no picker: a dead panel's sheet may never
    ///   call its handler, and a caller that waits on it would wait forever.
    public func panel() -> NSOpenPanel? { store.panel() }

    /// Pays the process's first panel once the person has paused (no input for a second), so its cost never
    /// lands on a keystroke or the first click. Bounded: after ten busy checks it waits for the click. Runs once
    /// per process. A view that offers the picker calls this when it reaches a window.
    public func warmWhenIdle() { store.warmWhenIdle() }

    /// Starts ``warmWhenIdle()`` when `schedule` runs its work: the app passes its launch's first idle moment
    /// (`LaunchSettle.whenSettled`), so the first click on a picker does not pay the process's first panel even
    /// before a view that offers it reached a window.
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
