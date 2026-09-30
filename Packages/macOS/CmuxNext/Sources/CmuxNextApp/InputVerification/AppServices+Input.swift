import AppKit
import CmuxNextControl

// Input verification wiring (plans/cmux-next/input-spec.md): the journal
// policy, the app-wide event tap into the journal, and the invariant
// monitor's triggers.
extension AppServices {
    func startInputVerification() {
        let journal = InputJournal.shared
        journal.configure(InputJournalPolicy.resolve(isDebugBuild: ControlService.isDebugBuild, tag: environment.tag,
                                                     environment: ProcessInfo.processInfo.environment))
        let monitor = InputInvariantMonitor(tag: environment.tag)
        monitor.services = self
        inputMonitor = monitor
        (NSApp as? CmuxApplication)?.inputObserver = { event in
            journal.record(event)
            switch event.type {
            case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp: monitor.noteChange()
            default: break
            }
        }
        let surfaces = surfaceInvariant
        cache.onPresentationChange = {
            surfaces.noteChange()
            monitor.noteChange()
        }
    }

    /// Journals `controller`'s focus transitions (with a checkpoint every
    /// `checkpointInterval` transitions, so replay can start mid-ring) and
    /// asks the monitor to check once they settle.
    func observeFocus(of controller: WindowController) {
        let journal = InputJournal.shared
        let monitor = inputMonitor
        var sinceCheckpoint = Int.max
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
            }
        }
    }
}
