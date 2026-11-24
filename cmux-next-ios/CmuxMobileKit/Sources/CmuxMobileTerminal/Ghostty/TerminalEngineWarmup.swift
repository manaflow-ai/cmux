#if os(iOS)
import Foundation
import OSLog
import QuartzCore

/// Starts the terminal engine (`ghostty_init`, the app's config, `ghostty_app_new`) once, when the
/// main thread first goes idle after the shell is on screen, instead of inside the first tap that
/// opens a terminal. The first terminal's open then pays only for its own surface.
///
/// Once per process: the first `schedule()` adds one run-loop observer that removes itself the first
/// time it fires; every later call returns at once. A terminal opened before then starts the engine
/// itself, as before (`CmuxMobileGhosttyApp.shared()` is idempotent).
@MainActor
public final class TerminalEngineWarmup {
    public static let shared = TerminalEngineWarmup()

    private static let log = Logger(subsystem: "dev.cmux.mobile", category: "timing")
    private var scheduled = false

    private init() {}

    /// Starts the engine the next time the main run loop is about to wait (nothing else queued).
    public func schedule() {
        guard !scheduled else { return }
        scheduled = true
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, 0) { observer, _ in
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            // main-proof: the observer is on the main run loop.
            MainActor.assumeIsolated { TerminalEngineWarmup.shared.warm() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private func warm() {
        let start = CACurrentMediaTime()
        guard (try? CmuxMobileGhosttyApp.shared()) != nil else { return }
        Self.log.info("timing launch terminal_engine_warm \(Int(((CACurrentMediaTime() - start) * 1000).rounded()), privacy: .public)ms")
    }
}
#endif
