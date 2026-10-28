import AppKit
import CmuxNextCompat
import CoreGraphics
import Foundation

/// Launch work that is pure and thread-safe, started on a background thread
/// at the top of `main` so it overlaps AppKit's own start-up instead of
/// running inside `applicationDidFinishLaunching` (about 150 ms from
/// process start on a loaded machine; the catalog alone took 50-70 ms on
/// the main thread). Work no first frame reads waits for the launch order
/// instead: the login shell's environment
/// (`DaemonLauncher.captureLoginEnvironment(after:)`) and the palette's
/// string tables (`LaunchFirstOpenWarmups`). The terminal's Metal device and fonts warm on their own thread once
/// the launch's features resolve (`TerminalLaunchPrefetch`), not behind this one: the catalog
/// would hold them back 50-70 ms.
///
/// The App passes its own pure warm-ups as `work`: the action catalog's
/// launch build (`ActionCatalogLaunch.build`), so the registry's read on the
/// main thread before the first window finds it ready;
/// `ActionCatalogLaunch.mainAccess` records how that read went
/// (`debug.startup`'s `action_catalog_main_wait_ms`), and the
/// `action_catalog_built` launch mark is when this thread finished it (no
/// mark when main claimed the build first). The icon pack and catalog decode
/// on their own thread (the App passes `IconPack.decodeBundledInBackground`)
/// and mark `icons_decoded`.
/// The icon decode and launch-mark sink are injected (the App's, or
/// `LaunchIconWarmupTests`'s recorders).
public struct LaunchWarmup: Sendable {
    private let work: @Sendable () -> Void
    private let decodeIcons: @Sendable (_ decoded: @escaping @Sendable () -> Void) -> Void
    private let markLaunch: @Sendable (String) -> Void

    /// - Parameters:
    ///   - work: The App's pure warm-ups, run first on the warm-up thread.
    ///   - decodeIcons: Starts the icon pack and catalog decode off main; calls its argument, on any thread, when done.
    ///   - markLaunch: The launch-mark sink (`DebugTimings.markLaunch` in the App).
    public init(
        work: @escaping @Sendable () -> Void,
        decodeIcons: @escaping @Sendable (_ decoded: @escaping @Sendable () -> Void) -> Void,
        markLaunch: @escaping @Sendable (String) -> Void
    ) {
        self.work = work
        self.decodeIcons = decodeIcons
        self.markLaunch = markLaunch
    }

    public func start() {
        let work = work
        let markLaunch = markLaunch
        // qos-allow: a frame waits for it (userInteractive): main reads the catalog, the menu's symbol and the
        // display UUIDs before its first frame; below main's QoS a loaded machine ran them after main reached them.
        let thread = Thread {
            work()
            // The SF Symbols catalog loads on first lookup (20 ms on the
            // main thread while the palette or the main menu first drew).
            _ = NSImage(systemSymbolName: "command", accessibilityDescription: nil)
            // The display UUID lookup loads ColorSync's display services on
            // first use: 60-90 ms on the main thread while the first window
            // was placed (`WindowPlacementFallback.displayID`).
            prewarmDisplayUUIDs()
        }
        thread.name = "cmux-next launch warm-up"
        thread.qualityOfService = .userInteractive
        thread.start()
        // Its own thread: the connecting screen's strings can be read before the work above ends.
        Bundle.warmResourceBundlesInBackground()
        // The restored window's tab strip and sidebar read the icon pack and catalog before the first frame.
        decodeIcons { markLaunch("icons_decoded") }
    }
}

private func prewarmDisplayUUIDs() {
    var displays = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    // SAFETY: CGGetActiveDisplayList writes at most displays.count IDs into the array's storage and the count
    // into a local, both live for the call. CGDisplayCreateUUIDFromDisplayID follows the Create rule (+1),
    // which takeRetainedValue balances.
    guard unsafe CGGetActiveDisplayList(UInt32(displays.count), &displays, &count) == .success else { return }
    for display in displays.prefix(Int(count)) { _ = unsafe CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() }
}
