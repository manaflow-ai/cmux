import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextPalette
import CoreFoundation
import Foundation

/// Launch work that is pure and thread-safe, started on a background thread
/// at the top of `main` so it overlaps AppKit's own start-up instead of
/// running inside `applicationDidFinishLaunching` (about 150 ms from
/// process start on a loaded machine; the catalog alone took 50-70 ms on
/// the main thread).
///
/// `ActionCatalog.all` is a lazy global (`swift_once`): if the main thread
/// reaches it while this thread still builds it, the main thread waits for
/// the rest of that one build, never longer than building it itself.
enum LaunchWarmup {
    static func start() {
        // The login shell's environment (`$SHELL -l -i`, about 0.9 s) is
        // needed to spawn a daemon on a cold start and for each new
        // terminal's env; capture it while AppKit starts.
        DaemonLauncher.prewarmLoginEnvironment()
        let thread = Thread {
            _ = ActionCatalog.all
            PaletteController.prewarmStrings()
            // The SF Symbols catalog loads on first lookup (20 ms on the
            // main thread while the palette or the main menu first drew).
            _ = NSImage(systemSymbolName: "command", accessibilityDescription: nil)
        }
        thread.name = "cmux-next launch warm-up"
        thread.qualityOfService = .userInitiated
        thread.start()
    }
}

/// Runs a block once, the next time the main run loop is about to sleep
/// (nothing else to do): a one-shot before-waiting observer ordered after
/// AppKit's display and the Core Animation commit, so the pending frame is
/// already on its way. It never wakes the loop and costs nothing once run.
@MainActor
enum IdleOnce {
    static func schedule(_ work: @escaping @MainActor () -> Void) {
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max - 1) { _, _ in
            MainActor.assumeIsolated { work() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .defaultMode)
    }
}
