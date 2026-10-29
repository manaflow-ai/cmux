import Foundation

/// How long a layer-hosted page's resize may hold its window's Core Animation commit for
/// Chromium's frame at the new size (fork API 27 to 31, `cmux_browser_set_resize_sync`), in whole
/// milliseconds. From fork API 32 a page window never holds the commit and ``CEFLayerHosting``
/// sends no deadline (`CEFLayerHosting.hasResizeSync(apiVersion:)`).
///
/// Chromium's pre-commit wait (`CATransactionCoordinator`) runs inside the process's Core Animation
/// commit, on the main thread, in every commit while a page still waits for its frame at a new size.
/// That one commit carries every cmux window, whatever display each is on. During a split, close or
/// column spring that is every motion frame, and the wait is the longest deadline of the waiting
/// pages (not their sum). So the wait is capped at a share (``frameShare``) of the shortest frame
/// interval of all displays: cmux's own frame work keeps the rest. The `browserResize.syncDeadline`
/// tunable is the upper bound: 8 ms stays 8 ms with only 60 Hz displays and becomes 4 ms as soon as
/// one display runs at 120 Hz.
///
/// The cap bounds only the deadline the fork gets: Chromium checks it between whole UI tasks
/// (`WaitForSingleTaskToRun`), and its post-commit wait for the GPU process is separate (the
/// fork's `UpdateWindowGeometry` decides whether a resize starts that sync; see the design doc).
struct CEFResizeSyncDeadline: Equatable {
    /// The share of one display frame the wait may take. Half: the layout step, AppKit's display
    /// pass and the rest of the commit keep the other half.
    static let frameShare = 0.5

    /// The deadline the fork gets; 0 never holds the commit.
    let milliseconds: Int32

    /// - Parameters:
    ///   - tunableMilliseconds: `browserResize.syncDeadline` in ms (negative counts as 0).
    ///   - refreshIntervals: each display's shortest frame interval in seconds
    ///     (`NSScreen.minimumRefreshInterval` of every screen); none (no screen) keeps the tunable,
    ///     and an interval that is not positive is ignored.
    init(tunableMilliseconds: Int32, refreshIntervals: [Double]) {
        var value = max(0, tunableMilliseconds)
        if let shortest = refreshIntervals.filter({ $0 > 0 }).min() {
            // Rounded down: the cap is never passed (8.33 ms at 60 Hz is 8, 4.17 ms at 120 Hz is 4).
            let cap = Int32((shortest * Self.frameShare * 1_000).rounded(.down))
            value = min(value, cap)
        }
        milliseconds = value
    }
}

/// Host mode (``ChromiumHostResizeFence``): the main thread never waits for
/// a page's frame. The WindowServer holds the window's commit on a fence for at most one display
/// frame, and a page later than that shows its last frame on its background.
extension CEFResizeSyncDeadline {
    /// The fork's deadline for a fenced page resize, in display frames (the host passes at most
    /// `kMaxFenceDeadlineFrames`, ChromiumHost/src/host_resize.h).
    static let fenceFrames: UInt32 = 1

    /// The display frame a screen with no refresh interval is taken to have (60 Hz).
    static let defaultFrame: Duration = .microseconds(16_667)

    /// How long cmux waits for the host's answer to a fenced resize before it ends the window's
    /// fences: ``fenceFrames`` frames of the window's screen (`refreshInterval`, seconds; not positive:
    /// ``defaultFrame``). The answer comes when the host gave the fork its right, before the page draws.
    static func fenceDeadline(refreshInterval: Double) -> Duration {
        let frame = refreshInterval > 0 ? Duration.microseconds(Int64((refreshInterval * 1_000_000).rounded(.up))) : defaultFrame
        return frame * Int(fenceFrames)
    }
}
