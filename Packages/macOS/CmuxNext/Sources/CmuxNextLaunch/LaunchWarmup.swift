import AppKit
import CmuxNextCompat
import CoreGraphics
import Foundation

/// Launch work that is pure and thread-safe, started on a background thread
/// at the top of `main` so it overlaps AppKit's own start-up instead of
/// running inside `applicationDidFinishLaunching` (about 150 ms from
/// process start on a loaded machine; the catalog alone took 50-70 ms on
/// the main thread).
///
/// The App passes its own pure warm-ups as `work` (the action catalog, the
/// palette strings). `ActionCatalog.all` is a lazy global (`swift_once`): if
/// the main thread reaches it while this thread still builds it, the main
/// thread waits for the rest of that one build, never longer than building
/// it itself.
public struct LaunchWarmup: Sendable {
    private let work: @Sendable () -> Void

    /// - Parameter work: The App's pure warm-ups, run first on the warm-up thread.
    public init(work: @escaping @Sendable () -> Void) {
        self.work = work
    }

    public func start() {
        let work = work
        let thread = Thread {
            work()
            // The SF Symbols catalog loads on first lookup (20 ms on the
            // main thread while the palette or the main menu first drew).
            _ = NSImage(systemSymbolName: "command", accessibilityDescription: nil)
            // The display UUID lookup loads ColorSync's display services on
            // first use: 60-90 ms on the main thread while the first window
            // was placed (`WindowPlacementFallback.displayID`).
            Self.prewarmDisplayUUIDs()
        }
        thread.name = "cmux-next launch warm-up"
        thread.qualityOfService = .userInitiated
        thread.start()
        // Its own thread: the connecting screen's strings can be read before the work above ends.
        Bundle.warmResourceBundlesInBackground()
    }

    private static func prewarmDisplayUUIDs() {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(displays.count), &displays, &count) == .success else { return }
        for display in displays.prefix(Int(count)) { _ = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() }
    }
}
