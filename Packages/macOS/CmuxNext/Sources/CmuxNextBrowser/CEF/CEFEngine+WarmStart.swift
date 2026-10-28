import Foundation

/// The warm start's two parts (``CEFLoadedStart``): the load awaited off the caller's turn, then
/// `CefInitialize` on a turn the caller picks.
extension CEFEngine {
    /// Returns once the framework load that `preload` started ended (at once when none runs), or in
    /// host mode once the host attached. After it, ``initializeLoaded(reason:)`` starts Chromium with
    /// no await.
    public func libraryLoadEnded() async {
        await loadedStart.loadEnded()
    }

    /// Runs `CefInitialize` (about 80-160 ms on the main thread) on this turn, once
    /// ``libraryLoadEnded()`` returned: a caller that picked an idle moment (ChromiumWarmup's step)
    /// pays it there. `reason` names why Chromium starts (`restoredTab`, `newTabMenu`, `palette`).
    ///
    /// - Returns: True when Chromium runs; false when no load has ended yet, or Chromium failed or shut down.
    @discardableResult
    public func initializeLoaded(reason: String) -> Bool {
        guard layout != nil else { return false }
        adoptStores()
        return loadedStart.start(trigger: reason)
    }
}
