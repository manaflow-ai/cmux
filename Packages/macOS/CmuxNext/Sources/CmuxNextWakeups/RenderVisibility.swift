import AppKit

/// Whether a display link's frames reach the screen: ``RenderStarvationGuard`` counts a late link
/// only when a person could see its frames. A window that is occluded, miniaturized or on a
/// sleeping display draws nothing anyone waits for, and its link may stop on its own, so its
/// lateness never holds other work.
///
/// ``AppKitRenderVisibility`` asks AppKit until the window and app visibility nodes feed it
/// (plans/cmux-next/chrome-parity/p06-scheduler.md tasks 020 and 022, Chrome's
/// `content::Visibility`); tests pass a fake.
@MainActor
public protocol RenderVisibility {
    /// Whether frames `scheduler` drives show now. A screen-hosted scheduler (no window) serves every
    /// window: its frames show while its own display is there and awake and any of the app's windows
    /// shows. Asked once per late period.
    func showsFrames(of scheduler: FrameScheduler) -> Bool
}

/// ``RenderVisibility`` from AppKit: a window shows when it is on screen, not miniaturized, at least
/// partly unoccluded, and its display is awake (`CGDisplayIsAsleep`). A screen-hosted scheduler's
/// frames show only while the display its link is on (``FrameScheduler/display``) is still connected
/// and awake, and some window of the app shows, on any display: its frames (the daemon drain, the
/// posted work) reach every window.
@MainActor
public struct AppKitRenderVisibility: RenderVisibility {
    /// AppKit's answer.
    public nonisolated init() {}

    /// Whether `scheduler`'s frames reach a screen now (its window shows, or a screen host's display is awake and a window of the app shows).
    public func showsFrames(of scheduler: FrameScheduler) -> Bool {
        if let window = scheduler.window { return Self.shows(window) }
        guard scheduler.isScreenHost, let app = NSApp else { return false }
        if let display = scheduler.display {
            guard NSScreen.screens.contains(where: { Self.number(of: $0) == display }), CGDisplayIsAsleep(display) == 0 else {
                return false
            }
        }
        return app.windows.contains(where: Self.shows)
    }

    private static func shows(_ window: NSWindow) -> Bool {
        guard window.isVisible, !window.isMiniaturized, window.occlusionState.contains(.visible), let screen = window.screen else {
            return false
        }
        guard let display = number(of: screen) else { return true }
        return CGDisplayIsAsleep(display) == 0
    }

    private static func number(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
