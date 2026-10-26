public import CmuxNextBrowser
public import Foundation

/// What ``ChromiumWarmup`` asks of the Chromium engine. `CEFEngine` is the app's; tests pass
/// a stand-in that records the calls.
@MainActor
public protocol ChromiumWarmupEngine: AnyObject, Sendable {
    var availability: BrowserEngineAvailability { get }
    /// True once Chromium answers in this process.
    var isRunning: Bool { get }
    /// Maps the framework on a background thread (in-process backend only).
    func preload()
    /// Returns once the framework load `preload` started ended.
    func libraryLoadEnded() async
    /// True when this app opened a Chromium tab within `window`.
    func usedRecently(within window: TimeInterval) async -> Bool
    /// Starts Chromium: `CefInitialize` in-process, or the Chromium Host.
    func warmStart(reason: String) async
    /// Builds the spare Chromium window (`CEFSpareWindow`, in-process backend only).
    @discardableResult func prepareSpareWindow() -> Bool
    /// Runs when no spare Chromium window is ready.
    var onSpareWindowNeeded: (@MainActor () -> Void)? { get set }
}

extension CEFEngine: ChromiumWarmupEngine {}
