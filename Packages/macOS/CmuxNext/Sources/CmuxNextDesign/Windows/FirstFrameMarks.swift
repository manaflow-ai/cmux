public import AppKit

/// Launch marks that split the span between a window ordered in and its first frame committed (RFD 0134 Table 4 row 4,
/// 170 to 210 ms). Marks only: it reads what the window and the run loop do and changes nothing. Made just before the
/// launch window is ordered in; each mark is reported once.
///
/// - `frame.window_update`: the window's first `didUpdate` (AppKit's layout and display pass for it ran).
/// - `frame.window_expose`: the window's first `didExpose`.
/// - `frame.occlusion_visible`: the window's occlusion state first reads visible (the window server shows it).
/// - `frame.loop_1` to `frame.loop_4`: the run loop's first four before-waiting passes after this was made, each run
///   after Core Animation's own commit observer (order 2,000,000), so each is a transaction commit that finished. The gaps
///   between them are the main-thread turns the frame commit queued behind.
///
/// ``NSWindow/commitFirstFrameNow(mark:)`` adds `window.display_done` and `window.flush_done`.
@MainActor
public final class FirstFrameMarks {
    private var tokens: [NSObjectProtocol] = []
    private var fired: Set<String> = []
    private var passes = 0
    private var loop: CFRunLoopObserver?
    private let mark: (String) -> Void
    private let finished: () -> Void

    /// - Parameters:
    ///   - mark: Records a launch mark by name.
    ///   - finished: Called once, after the fourth run-loop pass, when the observers are gone.
    public init(window: NSWindow, mark: @escaping (String) -> Void, finished: @escaping () -> Void = {}) {
        self.mark = mark
        self.finished = finished
        let center = NotificationCenter.default
        for (name, label) in [(NSWindow.didUpdateNotification, "frame.window_update"), (NSWindow.didExposeNotification, "frame.window_expose")] {
            tokens.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.fire(label) }
            })
        }
        tokens.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self, weak window] _ in
            MainActor.assumeIsolated { if window?.occlusionState.contains(.visible) == true { self?.fire("frame.occlusion_visible") } }
        })
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_000_001) { [weak self] _ in
            MainActor.assumeIsolated { self?.loopPassed() }
        }
        loop = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private func fire(_ label: String) {
        guard fired.insert(label).inserted else { return }
        mark(label)
    }

    private func loopPassed() {
        passes += 1
        fire("frame.loop_\(passes)")
        guard passes >= 4 else { return }
        stop()
        finished()
    }

    private func stop() {
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens = []
        if let loop { CFRunLoopRemoveObserver(CFRunLoopGetMain(), loop, .commonModes) }
        loop = nil
    }
}
