import AppKit
import os

/// Launch marks that split the span between `window.ordered_front` and `first_window_frame_committed` (RFD 0134 Table 4
/// row 4, 170 to 210 ms), marks only. Armed once, just before the launch window is ordered in:
///
/// - `frame.window_update`: the window's first `didUpdate` (AppKit's layout and display pass for it ran).
/// - `frame.window_expose`: the window's first `didExpose`.
/// - `frame.occlusion_visible`: the window's occlusion state first reads visible (the window server shows it).
/// - `frame.loop_1` to `frame.loop_4`: the run loop's first four before-waiting passes after the order-in, run after
///   Core Animation's own commit observer (order 2,000,000), so each one is a transaction commit that finished. The gaps
///   between them are the main-thread turns the frame commit queued behind.
///
/// `window.display_done` and `window.flush_done` come from ``NSWindow/commitFirstFrameNow(mark:)``.
@MainActor
enum LaunchFrameMarks {
    private static var armed = false
    private static let passes = OSAllocatedUnfairLock(initialState: 0)

    static func arm(_ window: NSWindow) {
        guard !armed else { return }
        armed = true
        let center = NotificationCenter.default
        for (name, mark) in [(NSWindow.didUpdateNotification, "frame.window_update"), (NSWindow.didExposeNotification, "frame.window_expose")] {
            nonisolated(unsafe) var token: NSObjectProtocol?
            token = center.addObserver(forName: name, object: window, queue: .main) { _ in
                DebugTimings.markLaunch(mark)
                if let token { center.removeObserver(token) }
            }
        }
        nonisolated(unsafe) var occlusion: NSObjectProtocol?
        occlusion = center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { note in
            guard (note.object as? NSWindow)?.occlusionState.contains(.visible) == true else { return }
            DebugTimings.markLaunch("frame.occlusion_visible")
            if let occlusion { center.removeObserver(occlusion) }
        }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_000_001) { observer, _ in
            let pass = passes.withLock { count -> Int in count += 1; return count }
            DebugTimings.markLaunch("frame.loop_\(pass)")
            if pass >= 4, let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}
