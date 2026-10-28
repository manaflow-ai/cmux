import AppKit
import CmuxNextCompat
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextFocus
import CmuxNextInput
import CmuxNextInputModel
import CmuxNextWakeups

/// Input verification (plans/cmux-next/input-spec.md): the journal policy,
/// the input tap's events into the journal, the invariant monitor and its
/// triggers, the windows' focus journaling, and in no-activate mode the
/// keyboard guard (`InputVerificationService+NoActivateGuard.swift`). One per
/// app, owned by `AppServices.input`; observers live as long as the app.
final class InputVerificationService {
    /// Input invariants and desync reports; set by `start` (nil before it).
    private(set) var monitor: InputInvariantMonitor?
    /// Any window's move, resize, screen and deminiaturize notices (`observeWindowGeometry`).
    private var geometrySubscriptions: [EventSubscription] = []
    /// Each cmux window's frame as last journaled, so a notice journals only the windows that moved.
    private var journaledFrames: [ObjectIdentifier: NSRect] = [:]
    /// No-activate mode only: gives back a keyboard the user did not give.
    var keyboardGuard: NoActivateKeyboardGuard?
    /// No-activate mode only: the guard's activation and key-window subscriptions.
    var keyboardGuardSubscriptions: [EventSubscription] = []
    /// No-activate mode only: another app's activation, with the app the notice names.
    var keyboardGuardActivation: MainActorObservation?
    /// The journal's and the monitor's subscription to the input tap (before the key router).
    private var journalSubscription: InputSubscription?
    /// No-activate mode only: the keyboard guard's subscription to the person's key and mouse presses.
    var keyboardGuardSubscription: InputSubscription?
    private weak var services: AppServices?

    /// Configures the journal, subscribes it to the input tap and installs the
    /// monitor's triggers (the `InputVerification.start` launch post).
    /// The no-activate keyboard guard is an NSApp input hook: `AppServices.init`
    /// installs it (`startNoActivateGuard(tap:appEvents:mainWork:work:)`), before the app activates.
    func start(services: AppServices) {
        self.services = services
        let journal = InputJournal.shared
        let tag = services.environment.tag
        journal.configure(InputJournalPolicy.resolve(isDebugBuild: ControlService.isDebugBuild, tag: tag,
                                                     environment: ProcessInfo.processInfo.environment))
        let monitor = InputInvariantMonitor(tag: tag, deadlines: services.mainDeadlines, runner: services.work)
        monitor.services = services
        self.monitor = monitor
        journalSubscription = Self.subscribeJournal(journal, to: services.inputTap) { monitor.noteChange() }
        observeWindowGeometry(services.appEvents, journal: journal, monitor: monitor)
        // M1: a mirror write outside daemon apply and the intent overlay is
        // checked (and reported) once input settles.
        services.daemon.store.onMirrorViolation = { [weak monitor] _ in monitor?.noteChange() }
        services.cache.presentationChanges.subscribe("input-monitor") { [weak monitor] in monitor?.noteChange() }
    }

    /// Records each key, flags, button, drag and scroll event from `tap` into `journal` before the key
    /// router (pointer moves carry no focus), and calls `noteChange` on a press or a left mouse-up (the
    /// invariant monitor's trigger).
    static func subscribeJournal(_ journal: InputJournal, to tap: InputEventTap,
                                 noteChange: @escaping @MainActor () -> Void) -> InputSubscription {
        tap.subscribe(class: [.key, .flags, .button, .drag, .scroll]) { event in
            journal.record(event)
            switch event.type {
            case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp: noteChange()
            default: break
            }
        }
    }

    /// A window moved or resized by any source (a drag, an Accessibility
    /// client such as Rectangle, a display or Space change): journal the
    /// frame of each cmux window that moved and check the Chromium page
    /// geometry (G1) once it settles. A page window that moved on its own (an
    /// AX client that got the page window) is checked too: any window's
    /// notice notes a change, and the monitor's settle deadline folds them.
    /// The app's one observer per notice (`AppServices.appEvents`); the
    /// subscriptions live as long as the app.
    private func observeWindowGeometry(_ events: AppEvents, journal: InputJournal, monitor: InputInvariantMonitor) {
        let changed: @MainActor () -> Void = { [weak self] in
            self?.journalMovedWindows(journal)
            monitor.noteChange()
        }
        let owner = "InputVerification.windowGeometry"
        geometrySubscriptions = [
            events.subscribe(NSWindow.didMoveNotification, owner: owner, changed),
            events.subscribe(NSWindow.didResizeNotification, owner: owner, changed),
            events.subscribe(NSWindow.didEndLiveResizeNotification, owner: owner, changed),
            events.subscribe(NSWindow.didChangeScreenNotification, owner: owner, changed),
            events.subscribe(NSWindow.didDeminiaturizeNotification, owner: owner, changed),
        ]
    }

    /// Journals the frame of each cmux window whose frame differs from the one last journaled.
    private func journalMovedWindows(_ journal: InputJournal) {
        guard let controllers = services?.windows.controllers else { return }
        var frames: [ObjectIdentifier: NSRect] = [:]
        for controller in controllers {
            guard let window = controller.window else { continue }
            let frame = window.frame, key = ObjectIdentifier(window)
            frames[key] = frame
            guard journaledFrames[key] != frame else { continue }
            journal.appendWindowFrame(window: controller.state.id, (frame.minX, frame.minY, frame.width, frame.height))
        }
        journaledFrames = frames
    }

    /// Journals `controller`'s focus transitions (with a checkpoint every
    /// `checkpointInterval` transitions, so replay can start mid-ring) and
    /// asks the monitor to check once they settle.
    func observeFocus(of controller: WindowController) {
        let journal = InputJournal.shared
        let monitor = self.monitor
        let services = self.services
        var sinceCheckpoint = Int.max - 1
        // The notification and location-trail observers act on the settled
        // keyboard target: each runs only when what it reads changed. The
        // trail also reads the active window, a shown top page and the
        // selected workspace (a settle it skipped under a top page records
        // once the page hides).
        var notified: FocusState.SettleKey?
        var trailed: TrailSettleKey?
        controller.focus.settledObserver = { [weak services, weak controller] state in
            services?.keyRouter.focusDidSettle(state, in: controller?.window)
            guard let controller else { return }
            // Chips shown for a held modifier follow the new focus (pane navigation while held).
            controller.shortcutHints?.focusDidSettle()
            services?.windows.recordSaver.focusDidSettle(controller.state, pane: state.pane)
            let key = state.settleKey
            if key != notified {
                notified = key
                services?.notifications.focusDidSettle(state, in: controller)
                // What new terminals and chats copy (NEW-WORK-INHERITS-CONTEXT).
                services?.noteWorkFocus(state, in: controller)
            }
            let trail = TrailSettleKey(focus: key, active: services?.windows.active === controller,
                                       topPage: controller.shownTopPage != nil, workspace: controller.state.workspaceID)
            if trail != trailed {
                trailed = trail
                services?.locationTrail.focusDidSettle(state, in: controller)
            }
        }
        controller.focus.observer = { [weak state = controller.state, weak focus = controller.focus] observation in
            // A no-op reduction (a responder report of the focus the window
            // already has) changes nothing the monitor checks.
            if case .reduced(_, _, _, false) = observation {} else { monitor?.noteChange() }
            guard journal.isEnabled else { return }
            let window = state?.id
            switch observation {
            case .reduced(let event, _, let next, _):
                journal.append(window: window, .focus(event, after: FocusDigest(next)))
                sinceCheckpoint += 1
                // The state after this event (the machine holds only the
                // current one): replay starts from it with the next event.
                if sinceCheckpoint >= InputJournal.checkpointInterval, let focus {
                    sinceCheckpoint = 0
                    journal.append(window: window, .focusCheckpoint(focus.checkpoint()))
                }
            case .suppressedResponder(let responder):
                journal.append(window: window, .responder(responder, suppressed: true))
            case .refusedByRun:
                // Nothing changed: the run had no view-change permission.
                break
            }
        }
    }
}

/// What `LocationTrailService.focusDidSettle` reads: the focus and the
/// window facts it skips on.
private struct TrailSettleKey: Hashable {
    var focus: FocusState.SettleKey
    var active: Bool
    var topPage: Bool
    var workspace: String?
}
