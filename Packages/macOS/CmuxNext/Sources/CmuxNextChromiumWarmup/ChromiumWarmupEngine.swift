public import CmuxNextBrowser
public import Foundation

/// What ``ChromiumWarmup`` drives: Chromium's start steps and its spare windows. ``CEFEngine`` in the
/// app; tests pass a fake that records the steps (and whether input was pending when each ran).
@MainActor
public protocol ChromiumWarmupEngine: AnyObject {
    var availability: BrowserEngineAvailability { get }
    /// Whether Chromium runs (`CefInitialize` finished).
    var isRunning: Bool { get }
    /// True when this app opened a Chromium tab within `window`.
    func usedRecently(within window: TimeInterval) async -> Bool
    /// Maps the framework on a background thread; no Chromium code runs.
    func preload()
    /// Returns once the framework load that `preload` started ended (in host mode, the host attached).
    func libraryLoadEnded() async
    /// Runs `CefInitialize` for `reason` on this turn, once the load ended; true when Chromium runs.
    @discardableResult
    func initializeLoaded(reason: String) -> Bool
    /// Builds the next missing spare window, the pages profile's too with `pages`; `pages` false
    /// closes an untaken pages spare. True when one started.
    @discardableResult
    func prepareSpareWindow(pages: Bool) -> Bool
    /// Stops keeping a pages spare window and closes an untaken one.
    func dropPagesSpareWindow()
    /// How many untaken spare windows are up (or being built).
    var spareWindowCount: Int { get }
    /// Holds the spare windows for memory pressure: `true` refuses new ones and give-backs until
    /// `false`, and keeps the untaken ones.
    func holdSpareWindows(_ held: Bool)
    /// Closes the untaken spare windows (critical memory pressure).
    func closeUntakenSpareWindows()
    /// Runs when a wanted spare window is not ready, so the warmup makes one at an idle moment.
    var onSpareWindowNeeded: (@MainActor () -> Void)? { get set }
}

extension CEFEngine: ChromiumWarmupEngine {}
