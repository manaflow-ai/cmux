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
        observeWindowGeometry(journal: journal, monitor: monitor)
        let surfaces = surfaceInvariant
        cache.onPresentationChange = {
            surfaces.noteChange()
            monitor.noteChange()
        }
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
            inputGeometryObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated {
                    guard let window, let controllers = self?.windows.controllers else { return }
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
