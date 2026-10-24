import CoreFoundation

/// Counts the main run loop's wakes while a timed action run is inside its synchronous work
/// (``ActionRegistry`` signposts).
///
/// The main run loop cannot sleep while a handler runs on it unless the handler opened a nested
/// run loop. Only a loop a person drives counts: a menu's event tracking (`NSMenu` pop-up, a
/// context menu) or a modal panel (`runModal`, a save panel without a window). A wake in such a
/// mode means the run's sample holds the person's dwell, and a run started inside that loop answers
/// a press of its own. A wake in any other mode (a handler spinning the default mode for a helper's
/// reply) is a stall the person feels: it is not counted, so the sample stays in the latency rows.
@MainActor
final class RunLoopWakeWatch {
    init() {}

    /// The run-loop modes a nested loop runs in while it waits for the person: a menu's (or a drag's)
    /// event tracking and a modal panel's (`NSEventTrackingRunLoopMode`, `NSModalPanelRunLoopMode`).
    nonisolated static let personDrivenModes: Set<String> = ["NSEventTrackingRunLoopMode", "NSModalPanelRunLoopMode"]

    /// Wakes seen in a person-driven mode while at least one run watched.
    private(set) var wakes = 0
    /// Runs watching now (a run inside a nested loop watches too); one observer serves them all.
    private var watchers = 0
    private var observer: CFRunLoopObserver?

    /// Starts watching for one run; pair with ``end()``.
    func begin() {
        watchers += 1
        guard observer == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.afterWaiting.rawValue,
                                                          true, 0) { [weak self] _, _ in
            // The mode the main run loop woke in: only a person-driven nested loop is dwell.
            guard let mode = CFRunLoopCopyCurrentMode(CFRunLoopGetMain()), Self.personDrivenModes.contains(mode.rawValue as String)
            else { return }
            // main-proof: the observer is added to the main run loop only (below).
            MainActor.assumeIsolated { self?.noteWake() }
        }
        // Common modes: a menu tracks in the event-tracking mode, a modal panel in the modal one.
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
        self.observer = observer
    }

    /// Stops watching for one run; the last one removes the observer.
    func end() {
        watchers -= 1
        guard watchers == 0, let observer else { return }
        CFRunLoopObserverInvalidate(observer)
        self.observer = nil
    }

    /// The main run loop woke (the observer, or a test standing in for a nested loop).
    func noteWake() { wakes += 1 }
}
