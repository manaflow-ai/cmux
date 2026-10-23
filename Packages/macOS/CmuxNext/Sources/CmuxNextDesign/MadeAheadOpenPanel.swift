public import AppKit
import CoreGraphics

/// The app's file picker, made ahead of the click: Home's "+" and an agent composer's
/// + > Attach files or images (a page's `<input type="file">`) take this panel.
///
/// `NSOpenPanel()` costs 105 to 120 ms on the main thread, about 300 ms for the process's
/// first one (frameworks and the panel service load), before `beginSheetModal` adds its own
/// 270 ms. Bench on a capture mini (macOS 26.3.1, a bare app, 2026-10-21): a new panel per
/// click first shows its sheet 830 ms after the click in a fresh process and 160 ms after it
/// later; the panel made ahead shows it after 95 ms, then 45 to 65 ms. One panel is made while
/// the person is idle and reused. The warm-up still costs that main-thread time once, at a
/// pause or while cmux is in the background. The logic is ``MadeAheadPanelStore``'s.
@MainActor
public final class MadeAheadOpenPanel {
    public static let shared = MadeAheadOpenPanel()

    private let store: MadeAheadPanelStore<NSOpenPanel>

    /// Whether the panel was made ahead of a click.
    public var isMade: Bool { store.isMade }
    /// The warm-up checks run so far.
    public var warmChecks: Int { store.warmChecks }
    /// Whether a warm-up check is pending.
    public var isWarming: Bool { store.isWarming }

    public init() {
        store = MadeAheadPanelStore(makePanel: { NSOpenPanel() }, warmCheck: openPanelWarmCheck)
    }

    /// The panel made ahead when it is free (no sheet or window shows it), else a new one (it
    /// shows on another window). Either comes as a new panel would: one file, no folders, every
    /// type, the system's prompt and no message; the caller sets what it needs.
    public func panel() -> NSOpenPanel { store.panel() }

    /// Makes the panel once the person has paused (no input for a second), so its cost never
    /// lands on a keystroke or the click itself. Bounded: after ten busy checks it waits for the
    /// click. A view that offers the picker calls this when it reaches a window.
    public func warmWhenIdle() { store.warmWhenIdle() }
}

/// Whether the app's warm-up may make an `NSOpenPanel` now.
@MainActor private func openPanelWarmCheck() -> OpenPanelWarmCheck {
    // Only in a running app: a process that never ran its event loop (a test host, a ci-step
    // mini with no open-panel service) would wait 10 s per ViewBridge endpoint, then die.
    // Checked when the check fires, not at schedule time: launch windows come before the loop runs.
    guard NSApp?.isRunning == true else { return .never }
    // Only in a login session on the console: from SSH or a fleet worker whose account is not the console user,
    // `NSOpenPanel()` blocks the main thread about 40 s on ViewBridge and comes back dead (2026-10-23).
    guard sessionIsOnConsole() else { return .never }
    // In the background the person types elsewhere: nothing here waits on the main thread.
    // In front, the time since the last input event (kCGAnyInputEventType, ~0).
    let anyInput = CGEventType(rawValue: ~0) ?? .null
    let idle = NSApp?.isActive == true ? CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput) : .infinity
    // Never inside a tracking loop (a drag, a menu, a resize): those count as busy.
    // RunLoop.current is unavailable in async code; this runs on the main actor.
    guard idle >= 1, RunLoop.main.currentMode == .default else { return .busy }
    return .ready
}

/// Whether this process's login session is the one on the console (`kCGSessionOnConsoleKey`, spelled out as
/// `NotificationPreviews.screenIsLocked` spells its key). No session dictionary at all (no window server session)
/// counts as off the console.
@MainActor private func sessionIsOnConsole() -> Bool {
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    return session?["kCGSSessionOnConsoleKey"] as? Bool ?? false
}
