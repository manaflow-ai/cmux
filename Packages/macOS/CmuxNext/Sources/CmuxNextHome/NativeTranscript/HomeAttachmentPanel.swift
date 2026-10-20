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
/// reused: a click pays only the sheet. The warm-up still costs that main-thread
/// time once, at a pause or while cmux is in the background.
@MainActor
enum HomeAttachmentPanel {
    private static var made: NSOpenPanel?

    /// A configured panel: the one made ahead when it is free, else a new one
    /// (it shows on another window).
    static func panel() -> NSOpenPanel {
        let free = made.flatMap { $0.isVisible || $0.sheetParent != nil ? nil : $0 }
        let panel = free ?? NSOpenPanel()
        if made == nil { made = panel }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = HomeStrings.attachPrompt
        panel.allowedContentTypes = HomeComposerCheck.pickerTypes
        return panel
    }

    /// Opens the picker as a sheet on `window` at once (no task hop). A window
    /// that already shows a sheet (the picker, a second click) opens none.
    static func present(for window: NSWindow, done: @escaping (_ urls: [URL]?) -> Void) {
        guard window.attachedSheet == nil else { return }
        let panel = panel()
        panel.beginSheetModal(for: window) { response in
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
            // In the background the person types elsewhere: nothing here waits on the main thread.
            // In front, the time since the last input event (kCGAnyInputEventType, ~0).
            let anyInput = CGEventType(rawValue: ~0) ?? .null
            let idle = NSApp.isActive ? CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput) : .infinity
            // Never inside a tracking loop (a drag, a menu, a resize): those count as busy.
            // RunLoop.current is unavailable in async code; this closure runs on the main actor.
            guard idle >= 1, RunLoop.main.currentMode == .default else {
                if triesLeft > 1 { check(after: .seconds(1), triesLeft: triesLeft - 1) }
                return
            }
            made = NSOpenPanel()
        }
    }
}
