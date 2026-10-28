import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextIcons
import Foundation

/// Launch work that is pure and thread-safe, started on a background thread
/// at the top of `main` so it overlaps AppKit's own start-up instead of
/// running inside `applicationDidFinishLaunching` (about 150 ms from
/// process start on a loaded machine; the catalog alone took 50-70 ms on
/// the main thread). Work no first frame reads waits for the launch order
/// instead (p08-startup-034): the login shell's environment
/// (`DaemonLauncher.captureLoginEnvironment(after:)`) and the palette's
/// string tables (`LaunchFirstOpenWarmups`). The terminal's Metal device and fonts warm on their own thread once
/// the launch's features resolve (`TerminalLaunchPrefetch`, p08-startup-091), not behind this one: the catalog
/// would hold them back 50-70 ms.
///
/// The action catalog is built here first (`ActionCatalogLaunch.build`), so
/// the registry's read on the main thread before the first window finds it
/// ready; `ActionCatalogLaunch.mainAccess` records how that read went
/// (`debug.startup`'s `action_catalog_main_wait_ms`), and the
/// `action_catalog_built` launch mark is when this thread finished it (no
/// mark when main claimed the build first). The icon pack and catalog decode
/// on their own thread (`IconPack.decodeBundledInBackground`, p08-startup-039)
/// and mark `icons_decoded`.
/// The icon decode and launch-mark sink are injected for `LaunchIconWarmupTests`.
struct LaunchWarmup {
    /// Starts the icon pack and catalog decode off main; calls its argument, on any thread, when done.
    var decodeIcons: (_ decoded: @escaping @Sendable () -> Void) -> Void = { IconPack.decodeBundledInBackground(then: $0) }
    var markLaunch: @Sendable (String) -> Void = { DebugTimings.markLaunch($0) }

    func start(catalog: ActionCatalogLaunch) {
        let markLaunch = markLaunch
        // qos-allow: a frame waits for it (userInteractive): main reads the catalog, the menu's symbol and the
        // display UUIDs before its first frame; below main's QoS a loaded machine ran them after main reached them.
        let thread = Thread {
            if catalog.build() { markLaunch("action_catalog_built") }
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

private nonisolated func prewarmDisplayUUIDs() {
    var displays = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    // SAFETY: CGGetActiveDisplayList writes at most displays.count IDs into the array's storage and the count
    // into a local, both live for the call. CGDisplayCreateUUIDFromDisplayID follows the Create rule (+1),
    // which takeRetainedValue balances.
    guard unsafe CGGetActiveDisplayList(UInt32(displays.count), &displays, &count) == .success else { return }
    for display in displays.prefix(Int(count)) { _ = unsafe CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() }
}
