import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextPalette
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
        // The login shell's environment (`$SHELL -l -i`, 1-17 s) is each
        // new terminal's env and is remembered for the next launch's
        // daemon; capture it while AppKit starts. Nothing that connects
        // the app waits for it.
        DaemonLauncher.prewarmLoginEnvironment()
        let thread = Thread {
            _ = ActionCatalog.all
            PaletteController.prewarmStrings()
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
    guard CGGetActiveDisplayList(UInt32(displays.count), &displays, &count) == .success else { return }
    for display in displays.prefix(Int(count)) { _ = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() }
}
