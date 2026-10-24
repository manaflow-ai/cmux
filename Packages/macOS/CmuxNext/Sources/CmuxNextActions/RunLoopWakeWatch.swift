import CoreFoundation

/// Counts the main run loop's wakes while a timed action run is inside its synchronous work
/// (``ActionRegistry`` signposts).
///
/// The main run loop cannot sleep while a handler runs on it unless the handler opened a nested
/// run loop that waited for the person (an `NSMenu` pop-up, `runModal`, a save panel without a
/// window). A wake during a run therefore means its sample holds the person's dwell time, and a
/// run started inside that loop answers a press of its own.
@MainActor
final class RunLoopWakeWatch {
    init() {}

    /// Wakes seen while at least one run watched.
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
