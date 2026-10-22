#if DEBUG
import AppKit
import CmuxNextSettings
import QuartzCore

/// The app main thread's work during a waited `fling` (``MainThreadFrameSampler``,
/// ``MainThreadFrameStats``): the reply's `main_*` fields, beside the page's own frame stats.
extension DebugAgentPane {
    /// A sampler for `fling` with `wait`, nil for every other action. Its deadline covers the
    /// page's warm-up (30 frames) and scroll with room to spare, within the socket's own deadline.
    static func mainThreadSampler(_ action: String, _ params: [String: JSONValue], view: NSView) -> MainThreadFrameSampler? {
        guard action == "fling", params["wait"]?.boolValue == true else { return nil }
        let seconds = min(max(0.1, params["seconds"]?.doubleValue ?? 3) + 10, 60)
        return MainThreadFrameSampler(view: view, timeout: .milliseconds(Int(seconds * 1000)))
    }

    /// Stops `sampler` and returns the `main_*` fields over the frames that ticked during the page's
    /// scroll (`scroll_ms_ago` in its reply, webviews acpmux/debug.ts); none when the reply has no
    /// scroll (an error).
    static func mainThreadFields(_ sampler: MainThreadFrameSampler, reply: [String: JSONValue]) -> [String: JSONValue] {
        let received = CACurrentMediaTime()
        sampler.stop()
        let ages = reply["scroll_ms_ago"]?.arrayValue?.compactMap(\.doubleValue) ?? []
        guard let window = MainThreadFrameStats.window(msAgo: ages, receivedAt: received) else { return [:] }
        return MainThreadFrameStats(sampler.frames, within: window).fields
    }
}
#endif
