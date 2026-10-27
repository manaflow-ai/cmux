import AppKit
import CmuxNextActions
import CmuxNextCompat
import Foundation

/// Launch work that is pure and thread-safe, started on a background thread
/// at the top of `main` so it overlaps AppKit's own start-up instead of
/// running inside `applicationDidFinishLaunching` (about 150 ms from
/// process start on a loaded machine; the catalog alone took 50-70 ms on
/// the main thread). Work no first frame reads waits for the launch order
/// instead (p08-startup-034): the login shell's environment
/// (`DaemonLauncher.captureLoginEnvironment(after:)`) and the palette's
/// string tables (`LaunchFirstOpenWarmups`).
///
/// `ActionCatalog.all` is a lazy global (`swift_once`): if the main thread
/// reaches it while this thread still builds it, the main thread waits for
/// the rest of that one build, never longer than building it itself.
enum LaunchWarmup {
    static func start() {
        let thread = Thread {
            _ = ActionCatalog.all
            // The SF Symbols catalog loads on first lookup (20 ms on the
            // main thread while the palette or the main menu first drew).
            _ = NSImage(systemSymbolName: "command", accessibilityDescription: nil)
            // The display UUID lookup loads ColorSync's display services on
            // first use: 60-90 ms on the main thread while the first window
            // was placed (`WindowPlacementFallback.displayID`).
            prewarmDisplayUUIDs()
        }
        thread.name = "cmux-next launch warm-up"
        thread.qualityOfService = .userInitiated
        thread.start()
        // Its own thread: the connecting screen's strings can be read before the work above ends.
        Bundle.warmResourceBundlesInBackground()
    }
}

private nonisolated func prewarmDisplayUUIDs() {
    var displays = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    // SAFETY: CGGetActiveDisplayList writes at most displays.count IDs into the array's storage and the count
    // into a local, both live for the call. CGDisplayCreateUUIDFromDisplayID follows the Create rule (+1),
    // which takeRetainedValue balances.
    guard unsafe CGGetActiveDisplayList(UInt32(displays.count), &displays, &count) == .success else { return }
    for display in displays.prefix(Int(count)) { _ = unsafe CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() }
}
