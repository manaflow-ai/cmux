public import AppKit
import CmuxNextWakeups
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
/// pause or while cmux is in the background.
@MainActor
public final class MadeAheadOpenPanel {
    public static let shared = MadeAheadOpenPanel()

    private var made: NSOpenPanel?
    private var madeDefaults: OpenPanelDefaults?
    /// Whether the panel was made ahead of a click.
    public var isMade: Bool { made != nil }
    /// The warm-up checks run so far, and whether another is pending.
    public private(set) var warmChecks = 0
    public var isWarming: Bool { timer.isScheduled }

    private let timer = DemandTimer(owner: "openPanel.madeAhead.warm")

    public init() {}

    /// The panel made ahead when it is free (no sheet or window shows it), else a new one (it
    /// shows on another window). Either comes as a new panel would: one file, no folders, every
    /// type, the system's prompt and no message; the caller sets what it needs.
    public func panel() -> NSOpenPanel {
        let free = made.flatMap { $0.isVisible || $0.sheetParent != nil ? nil : $0 }
        guard let panel = free else {
            let panel = NSOpenPanel()
            if made == nil { keep(panel) }
            return panel
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        panel.allowedContentTypes = []
        madeDefaults?.apply(to: panel)
        return panel
    }

    /// Makes the panel once the person has paused (no input for a second), so its cost never
    /// lands on a keystroke or the click itself. Bounded: after ten busy checks it waits for the
    /// click. A view that offers the picker calls this when it reaches a window.
    public func warmWhenIdle() {
        guard made == nil, !timer.isScheduled else { return }
        check(after: .seconds(2), triesLeft: 10)
    }

    /// Keeps `panel` for later clicks, unless its view service never answered (no prompt): then the next
    /// click makes a new one, and the launch goes on.
    private func keep(_ panel: NSOpenPanel) {
        guard let defaults = OpenPanelDefaults(of: panel) else { return }
        made = panel
        madeDefaults = defaults
    }

    private func check(after delay: Duration, triesLeft: Int) {
        timer.schedule(after: delay) { @MainActor [weak self] in
            guard let self else { return }
            warmChecks += 1
            // Only in a running app: a process that never ran its event loop (a test host, a ci-step
            // mini with no open-panel service) would wait 10 s per ViewBridge endpoint, then die.
            // Checked here, not at schedule time: launch windows come before the loop runs.
            guard made == nil, NSApp?.isRunning == true else { return }
            // In the background the person types elsewhere: nothing here waits on the main thread.
            // In front, the time since the last input event (kCGAnyInputEventType, ~0).
            let anyInput = CGEventType(rawValue: ~0) ?? .null
            let idle = NSApp?.isActive == true ? CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput) : .infinity
            // Never inside a tracking loop (a drag, a menu, a resize): those count as busy.
            // RunLoop.current is unavailable in async code; this closure runs on the main actor.
            guard idle >= 1, RunLoop.main.currentMode == .default else {
                if triesLeft > 1 { check(after: .seconds(1), triesLeft: triesLeft - 1) }
                return
            }
            keep(NSOpenPanel())
        }
    }
}
