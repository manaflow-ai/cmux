#if os(iOS)
import Foundation
import OSLog
import QuartzCore

/// Starts the terminal engine (`ghostty_init`, the app's config, `ghostty_app_new`) once, off the main
/// thread, once the shell's first frame is on screen, instead of inside the
/// first tap that opens a terminal. The first terminal's open then pays only for its own surface, and
/// the main thread (chat's first frame, scrolling) pays nothing for the engine.
///
/// Once per process: the first `schedule()` adds one display link that stops itself at its first
/// frame; every later call returns at once. A terminal opened while the build runs waits for
/// that build (`EngineBuild`); one opened before it starts builds the engine itself, as before.
@MainActor
public final class TerminalEngineWarmup: NSObject {
    public static let shared = TerminalEngineWarmup()

    private static let log = Logger(subsystem: "dev.cmux.mobile", category: "timing")
    private var scheduled = false

    override private init() {}

    private var link: CADisplayLink?

    /// Starts the engine build at the next display frame, which comes after the frame that put the
    /// shell on screen is committed. A run-loop `beforeWaiting` observer would run before Core
    /// Animation's own commit observer, so the build would contend with the first frame.
    public func schedule() {
        guard !scheduled else { return }
        scheduled = true
        let link = CADisplayLink(target: self, selector: #selector(frameShown))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func frameShown() {
        link?.invalidate()
        link = nil
        warm()
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
