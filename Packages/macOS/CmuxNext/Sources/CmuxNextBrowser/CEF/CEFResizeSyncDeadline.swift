import Foundation

/// How long a layer-hosted page's resize may hold its window's Core Animation commit for
/// Chromium's frame at the new size (fork API 27, `cmux_browser_set_resize_sync`), in whole
/// milliseconds.
///
/// Chromium's pre-commit wait (`CATransactionCoordinator`) runs inside the window's commit, on
/// the main thread, in every commit while a page still waits for its frame at a new size. During
/// a split, close or column spring that is every motion frame, and the wait is the longest
/// deadline of the waiting pages (not their sum). So the wait is capped at a share of the
/// display's frame interval (``frameShare``): cmux's own frame work keeps the rest, and the wait
/// alone never costs a frame. The `browserResize.syncDeadline` tunable is the upper bound:
/// 8 ms stays 8 ms at 60 Hz and becomes 4 ms at 120 Hz.
struct CEFResizeSyncDeadline: Equatable {
    /// The share of one display frame the wait may take. Half: the layout step, AppKit's display
    /// pass and the rest of the commit keep the other half.
    static let frameShare = 0.5

    /// The deadline the fork gets; 0 never holds the commit.
    let milliseconds: Int32

    /// - Parameters:
    ///   - tunableMilliseconds: `browserResize.syncDeadline` in ms (negative counts as 0).
    ///   - refreshInterval: the display's shortest frame interval in seconds
    ///     (`NSScreen.minimumRefreshInterval`); nil (no screen yet) keeps the tunable.
    init(tunableMilliseconds: Int32, refreshInterval: Double?) {
        var value = max(0, tunableMilliseconds)
        if let refreshInterval, refreshInterval > 0 {
            // Rounded down: the cap is never passed (8.33 ms at 60 Hz is 8, 4.17 ms at 120 Hz is 4).
            let cap = Int32((refreshInterval * Self.frameShare * 1_000).rounded(.down))
            value = min(value, cap)
        }
        milliseconds = value
    }
}
