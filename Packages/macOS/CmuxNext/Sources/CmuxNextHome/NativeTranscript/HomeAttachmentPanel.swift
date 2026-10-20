import AppKit
import CmuxNextWakeups
import CoreGraphics

/// The message box's file picker, made ahead of the click.
///
/// `NSOpenPanel()` costs 130 ms on the main thread, about 400 ms for the
/// process's first one (frameworks and the panel service load), before
/// `beginSheetModal` adds its own 270 ms (bench on macOS 27.0.1, a bare
/// app, 2026-10-20). The "+" button made a new panel on every click and
/// opened it a turn of the run loop later, so the sheet came up 0.7 s or
/// more after the click. One panel is made while the person is idle and
/// reused: a click pays only the sheet.
@MainActor
enum HomeAttachmentPanel {
    private static var made: NSOpenPanel?
    private static var showing = false

    /// The configured panel; made now when the idle warm-up has not run.
    static func panel() -> NSOpenPanel {
        let panel = made ?? NSOpenPanel()
        made = panel
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = HomeStrings.attachPrompt
        panel.allowedContentTypes = HomeComposerCheck.pickerTypes
        return panel
    }

    /// Opens the picker as a sheet on `window` at once (no task hop). A second
    /// click while it shows does nothing.
    static func present(for window: NSWindow, done: @escaping (_ urls: [URL]?) -> Void) {
        guard !showing, window.attachedSheet == nil else { return }
        let panel = panel()
        showing = true
        panel.beginSheetModal(for: window) { response in
            showing = false
            done(response == .OK ? panel.urls : nil)
        }
    }

    /// Makes the panel once the person has paused (no input for a second), so
    /// its cost never lands on a keystroke or the click itself. Bounded: after
    /// ten busy checks it waits for the click.
    static func warmWhenIdle() {
        guard made == nil, !timer.isScheduled else { return }
        check(after: .seconds(2), triesLeft: 10)
    }

    private static let timer = DemandTimer(owner: "home.attachmentPanel.warm")

    private static func check(after delay: Duration, triesLeft: Int) {
        timer.schedule(after: delay) { @MainActor in
            guard made == nil else { return }
            let anyInput = CGEventType(rawValue: ~0) ?? .null
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
            guard idle >= 1 else {
                if triesLeft > 1 { check(after: .seconds(1), triesLeft: triesLeft - 1) }
                return
            }
            // Default mode only: never inside a tracking loop (a drag or a menu).
            RunLoop.main.perform(inModes: [.default]) {
                MainActor.assumeIsolated { if made == nil { made = NSOpenPanel() } }
            }
        }
    }
}
