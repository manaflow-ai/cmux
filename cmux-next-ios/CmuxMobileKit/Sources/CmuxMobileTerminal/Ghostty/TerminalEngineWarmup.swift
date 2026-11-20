#if os(iOS)
import Foundation
import OSLog
import QuartzCore

/// Starts the terminal engine (`ghostty_init`, the app's config, `ghostty_app_new`) once, off the main
/// thread, when the main thread first goes idle after the shell is on screen, instead of inside the
/// first tap that opens a terminal. The first terminal's open then pays only for its own surface, and
/// the main thread (chat's first frame, scrolling) pays nothing for the engine.
///
/// Once per process: the first `schedule()` adds one run-loop observer that removes itself the first
/// time it fires; every later call returns at once. A terminal opened while the build runs waits for
/// that build (`EngineBuild`); one opened before it starts builds the engine itself, as before.
@MainActor
public final class TerminalEngineWarmup {
    public static let shared = TerminalEngineWarmup()

    private static let log = Logger(subsystem: "dev.cmux.mobile", category: "timing")
    private var scheduled = false

    private init() {}

    /// Starts the engine build the next time the main run loop is about to wait (nothing else queued).
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
        // The theme is read here on the main actor; the build itself runs on a utility thread.
        let colorLines = CmuxMobileGhosttyApp.productColorLines
        let log = Self.log
        DispatchQueue.global(qos: .utility).async {
            let start = CACurrentMediaTime()
            guard case .success = EngineBuild.shared.engine(colorLines: colorLines) else { return }
            log.info("timing launch terminal_engine_warm \(Int(((CACurrentMediaTime() - start) * 1000).rounded()), privacy: .public)ms off-main")
        }
    }
}
#endif
