import AppKit
import CmuxNextActions
import CmuxNextCompat
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
        let bundles = Thread { ResourceBundleWarmup.run() }
        bundles.name = "cmux-next resource bundle warm-up"
        bundles.qualityOfService = .userInitiated
        bundles.start()
    }
}

/// Opens every SwiftPM resource bundle in the app (`Contents/Resources/*.bundle`, 55 of them)
/// and loads its string table, on the warm-up thread. A module's first `Bundle.module` read
/// (any `String(localized:bundle: .module)`) otherwise creates the bundle on the main thread,
/// and `CFBundleCreate` lists the bundle's folder to find its version: on a cold file cache
/// (after an update) that held the main thread 2 s+ (Sentry MainThreadStall in
/// `_CFBundleGetBundleVersionForURL` from `DaemonRecoveryStrings.retryNow` while the connecting
/// screen built). NSBundle keeps one instance per path, so the later `Bundle.module` read gets
/// this one; `bundles` holds them for the life of the process all the same.
nonisolated enum ResourceBundleWarmup {
    private static let bundles = Mutex<[Bundle]>([])

    static func run(resources: URL? = Bundle.main.resourceURL) {
        guard let resources,
              let names = try? FileManager.default.contentsOfDirectory(atPath: resources.path) else { return }
        let opened = names.filter { $0.hasSuffix(".bundle") }.sorted().compactMap { name -> Bundle? in
            guard let bundle = Bundle(url: resources.appending(path: name, directoryHint: .isDirectory)) else { return nil }
            // Loads the Localizable table of the preferred language (a file read per bundle).
            _ = bundle.localizedString(forKey: "cmux.warmup", value: nil, table: nil)
            return bundle
        }
        bundles.withLock { $0 = opened }
    }
}

private nonisolated func prewarmDisplayUUIDs() {
    var displays = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(UInt32(displays.count), &displays, &count) == .success else { return }
    for display in displays.prefix(Int(count)) { _ = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() }
}

/// Runs a block once, the next time the main run loop is about to sleep
/// (nothing else to do): a one-shot before-waiting observer ordered after
/// AppKit's display and the Core Animation commit, so the pending frame is
/// already on its way. It never wakes the loop and costs nothing once run.
@MainActor
enum IdleOnce {
    static func schedule(_ work: @escaping @MainActor () -> Void) {
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max - 1) { _, _ in
            MainActor.assumeIsolated { work() } // main-proof: the observer is added only to CFRunLoopGetMain() (below)
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .defaultMode)
    }
}
