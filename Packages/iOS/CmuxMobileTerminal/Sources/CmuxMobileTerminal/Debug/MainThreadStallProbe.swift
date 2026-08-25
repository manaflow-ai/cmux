#if DEBUG
#if canImport(UIKit)
import CmuxMobileDiagnostics
import Foundation
import QuartzCore
import UIKit

/// Splits long main-thread stalls during scrolling into "Core Animation
/// commit" (layout + SwiftUI render flush) vs "everything else in the
/// runloop cycle" (event delivery, timers, main-queue blocks). CA installs
/// its commit observer on `kCFRunLoopBeforeWaiting` at order 2_000_000;
/// bracketing it with observers at 1_999_999 and 2_000_001 measures exactly
/// that window, which the display-link hitch attributor (`perf.hitch
/// dead_ms`) cannot see into.
@MainActor
enum MainThreadStallProbe {
    /// Updated per display-link frame; the probe logs only during scrolls.
    static var scrollActive = false
    private static var installed = false
    private static var cycleStartedAt: CFTimeInterval = 0
    private static var commitStartedAt: CFTimeInterval = 0
    private static var lastLogAt: CFTimeInterval = 0

    static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        addObserver(activity: .afterWaiting, order: -2_000_000) { now in
            cycleStartedAt = now
        }
        addObserver(activity: .beforeWaiting, order: 1_999_999) { now in
            commitStartedAt = now
        }
        addObserver(activity: .beforeWaiting, order: 2_000_001) { now in
            guard scrollActive, cycleStartedAt > 0, commitStartedAt >= cycleStartedAt else { return }
            let cycleMs = (now - cycleStartedAt) * 1000
            guard cycleMs > 10 else { return }
            let commitMs = (now - commitStartedAt) * 1000
            if now - lastLogAt >= 0.25 {
                lastLogAt = now
                MobileDebugLog.anchormux(
                    "perf.main.cycle ms=\(Int(cycleMs)) commit_ms=\(Int(commitMs)) "
                        + "other_ms=\(Int(max(0, cycleMs - commitMs)))"
                )
            }
        }
    }

    private static func addObserver(
        activity: CFRunLoopActivity,
        order: CFIndex,
        _ handler: @escaping @MainActor (CFTimeInterval) -> Void
    ) {
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            activity.rawValue,
            true,
            order
        ) { _, _ in
            // The main run loop's observers always fire on the main thread.
            MainActor.assumeIsolated { handler(CACurrentMediaTime()) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}
#endif
#endif
