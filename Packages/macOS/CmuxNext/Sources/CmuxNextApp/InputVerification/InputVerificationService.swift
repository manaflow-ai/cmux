import AppKit
import CmuxNextControl
import CmuxNextDaemon

/// Input verification (plans/cmux-next/input-spec.md): the journal policy,
/// the app-wide event tap into the journal, the invariant monitor and its
/// triggers, the windows' focus journaling, and in no-activate mode the
/// keyboard guard (`InputVerificationService+NoActivateGuard.swift`). One per
/// app, owned by `AppServices.input`; observers live as long as the app.
final class InputVerificationService {
    /// Input invariants and desync reports; set by `start` (nil before it).
    private(set) var monitor: InputInvariantMonitor?
    private var geometryObservers: [any NSObjectProtocol] = []
    /// No-activate mode only: gives back a keyboard the user did not give.
    var keyboardGuard: NoActivateKeyboardGuard?
    var keyboardGuardObservers: [any NSObjectProtocol] = []
    private weak var services: AppServices?

    /// Configures the journal, installs the event tap and the monitor's
    /// triggers, then the no-activate keyboard guard (it wraps the tap).
    func start(services: AppServices) {
        self.services = services
        let journal = InputJournal.shared
        let tag = services.environment.tag
        journal.configure(InputJournalPolicy.resolve(isDebugBuild: ControlService.isDebugBuild, tag: tag,
                                                     environment: ProcessInfo.processInfo.environment))
        let monitor = InputInvariantMonitor(tag: tag)
        monitor.services = services
        self.monitor = monitor
        (NSApp as? CmuxApplication)?.inputObserver = { event in
            journal.record(event)
            switch event.type {
            case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp: monitor.noteChange()
            default: break
            }
        }
        observeWindowGeometry(journal: journal, monitor: monitor)
        // M1: a mirror write outside daemon apply and the intent overlay is
        // checked (and reported) once input settles.
        services.daemon.store.onMirrorViolation = { [weak monitor] _ in monitor?.noteChange() }
        services.cache.presentationChanges.subscribe("input-monitor") { [weak monitor] in monitor?.noteChange() }
        startNoActivateGuard()
    }

    /// A cmux window moved or resized by any source (a drag, an
    /// Accessibility client such as Rectangle, a display or Space change):
    /// journal the frame and check the Chromium page geometry (G1) once it
    /// settles; a page window that moved on its own is checked too.
    /// Observers live as long as the app.
    private func observeWindowGeometry(journal: InputJournal, monitor: InputInvariantMonitor) {
        let names = [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                     NSWindow.didChangeScreenNotification, NSWindow.didDeminiaturizeNotification]
        for name in names {
            geometryObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated {
                    guard let window, let controllers = self?.services?.windows.controllers else { return }
                    if let controller = controllers.first(where: { $0.window === window }) {
                        let frame = window.frame
                        journal.appendWindowFrame(window: controller.state.id, (frame.minX, frame.minY, frame.width, frame.height))
                        monitor.noteChange()
                    } else if let parent = window.parent, controllers.contains(where: { $0.window === parent }),
                              WindowOverlayLayer.isContent(window) {
                        // A Chromium page window moved by itself (an AX client
                        // that got the page window): check G1 too.
                        monitor.noteChange()
                    }
                }
            })
        }
    }

    /// Journals `controller`'s focus transitions (with a checkpoint every
    /// `checkpointInterval` transitions, so replay can start mid-ring) and
    /// asks the monitor to check once they settle.
    func observeFocus(of controller: WindowController) {
        let journal = InputJournal.shared
        let monitor = self.monitor
        let services = self.services
        var sinceCheckpoint = Int.max
        controller.focus.settledObserver = { [weak services, weak controller] state in
            services?.notifications.focusDidSettle(state)
            services?.keyRouter.focusDidSettle(state, in: controller?.window)
            if let controller {
                services?.windows.recordSaver.focusDidSettle(controller.state, pane: state.pane)
                services?.locationTrail.focusDidSettle(state, in: controller)
            }
        }
        controller.focus.observer = { [weak state = controller.state] observation in
            monitor?.noteChange()
            guard journal.isEnabled else { return }
            let window = state?.id
            switch observation {
            case .reduced(let event, let previous, let next):
                if sinceCheckpoint >= InputJournal.checkpointInterval {
                    sinceCheckpoint = 0
                    journal.append(window: window, .focusCheckpoint(previous))
                }
                sinceCheckpoint += 1
                journal.append(window: window, .focus(event, after: FocusDigest(next)))
            case .suppressedResponder(let responder):
                journal.append(window: window, .responder(responder, suppressed: true))
            case .refusedByRun:
                // Nothing changed: the run had no view-change permission.
                break
            }
        }
    }
}
