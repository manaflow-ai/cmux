import AppKit
import CmuxNextWakeups
import CoreGraphics

/// Hides the cursor and holds it where it is while a page holds the pointer lock, as
/// `-[RenderWidgetHostViewCocoa setCursorLocked:]` does
/// (content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm):
/// `CGAssociateMouseAndMouseCursorPosition(NO)` and `[NSCursor hide]`, undone in the other order.
/// `lock` returns whether the system took the cursor (the dissociation succeeded), which `debug.cef`
/// `host_locks` reports. Tests pass a recorder.
struct ChromiumHostCursorLock {
    let lock: @MainActor () -> Bool
    let unlock: @MainActor () -> Void

    @MainActor static let system = ChromiumHostCursorLock(
        lock: {
            NSCursor.hide()
            return CGAssociateMouseAndMouseCursorPosition(0) == .success
        },
        unlock: {
            _ = CGAssociateMouseAndMouseCursorPosition(1)
            NSCursor.unhide()
        })
}

/// The held Escape's one-shot deadline, as `KeyboardLockController` runs a `base::OneShotTimer` of
/// `kHoldEscapeTime` from the Escape key down and stops it on the key up
/// (chrome/browser/ui/exclusive_access/keyboard_lock_controller.cc): the exit does not depend on key
/// repeat, which a person may have turned off. Tests pass a fake.
@MainActor
protocol ChromiumHostHoldTimer: AnyObject {
    /// Calls `fire` once, `delay` from now, unless ``stop()`` comes first; replaces a pending start.
    func start(after delay: Duration, _ fire: @escaping @MainActor @Sendable () -> Void)
    func stop()
}

/// ``ChromiumHostHoldTimer`` on the main thread's one deadline queue (`MainWorkScheduler.wakeUps`).
@MainActor
final class ChromiumHostWakeUpHoldTimer: ChromiumHostHoldTimer {
    private let deadlines: AlignedWakeups
    private var ticket: AlignedWakeups.Ticket?

    init(deadlines: AlignedWakeups) {
        self.deadlines = deadlines
    }

    func start(after delay: Duration, _ fire: @escaping @MainActor @Sendable () -> Void) {
        stop()
        ticket = deadlines.schedule(owner: "ChromiumHostExclusiveAccess.holdEscape", after: delay) { [weak self] in
            self?.ticket = nil
            fire()
        }
    }

    func stop() {
        guard let ticket else { return }
        self.ticket = nil
        deadlines.cancel(ticket)
    }
}
