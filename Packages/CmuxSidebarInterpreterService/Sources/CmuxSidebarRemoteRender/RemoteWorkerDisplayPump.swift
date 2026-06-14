import AppKit
import QuartzCore

/// Display-refresh-driven pump for the worker's never-ordered window.
///
/// Dirtiness signals (see ``RemoteWorkerHostingView`` and
/// ``RemoteWorkerWindow``) arm a `CADisplayLink`; each tick runs the
/// coordinator's pump once, and the first clean tick pauses the link, so an
/// idle worker has no periodic wakeups at all. Decisions live in
/// ``RenderPumpGate``; this class only owns the link plumbing.
///
/// The link comes from `NSScreen.displayLink(target:selector:)` (macOS 14+,
/// the non-deprecated `CVDisplayLink` replacement). It is deliberately bound
/// to a screen, not to the worker's view or window: the worker's window is
/// never on any display, so a view- or window-bound link would stay paused
/// forever. The screen choice only sets the tick rate; the commit target is
/// the remote context, which the host composites on whatever display it is
/// actually on.
@MainActor
final class RemoteWorkerDisplayPump: NSObject {
    private let onPump: @MainActor () -> Void
    private var gate = RenderPumpGate()
    private var link: CADisplayLink?
    private var screenObserver: NSObjectProtocol?

    /// Creates a pump that invokes `onPump` at most once per display refresh
    /// while dirty. `onPump` must end by calling ``pumpCompleted()`` (the
    /// coordinator's pump does).
    init(onPump: @escaping @MainActor () -> Void) {
        self.onPump = onPump
        super.init()
        // Displays can come and go; a link created against an unplugged
        // screen stops ticking silently. Drop it and let the next dirtiness
        // signal rebuild against the current screen.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rebuildLinkIfNeeded()
            }
        }
    }

    /// Records an invalidation; resumes the display link when the gate was
    /// clean.
    func noteInvalidation() {
        guard gate.markDirty() else { return }
        resumeLink()
    }

    /// Tells the gate a pump's commit landed (explicit message pumps and
    /// tick pumps both flush everything marked dirty so far), and parks the
    /// link immediately so a commit's own invalidation noise (layout marking
    /// the view dirty mid-pump) does not buy a throwaway wakeup.
    func pumpCompleted() {
        gate.pumpCompleted()
        link?.isPaused = true
    }

    /// Stops the link and releases its target retain. The worker normally
    /// lives for the whole process, but tests and future owners get a clean
    /// teardown.
    func invalidate() {
        link?.invalidate()
        link = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        switch gate.tickAction() {
        case .pump:
            onPump()
        case .pause:
            link.isPaused = true
        }
    }

    private func resumeLink() {
        if link == nil {
            // The window is never on a screen, so anchor the link to the
            // main screen (first screen as a faceless-process fallback).
            guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
            let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        link?.isPaused = false
    }

    private func rebuildLinkIfNeeded() {
        guard link != nil else { return }
        link?.invalidate()
        link = nil
        if gate.isDirty {
            resumeLink()
        }
    }
}
