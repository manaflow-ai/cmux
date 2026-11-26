import AppKit
import Foundation

/// How long an in-tree page's resize holds its window's commit, from how the window's pages kept up with the last
/// fences (``CEFInTreeHosting/pageViewResized()``, `CMUX_NEXT_CEF_FENCE_PACE=adaptive`).
///
/// The fixed waits (``CEFInTreeHosting/fenceTimeoutMs(windowResized:fullScreenTransition:refreshMs:)``) cost the pane
/// its wait whenever a page misses it: the window's commit is held to the deadline and the page still shows its last
/// frame. Here, per window:
/// - keeping up (the last ``window`` outcomes all presented, at least ``window`` of them): the wait grows to
///   ``longMs(base:refreshMs:windowResized:)``, so a page that is a little late joins its pane rather than lagging it;
/// - falling behind (``behindMisses`` or more misses in the last ``window``): no wait at all for ``behindSeconds``,
///   then one fence at the base wait probes again;
/// - otherwise the base wait.
///
/// The process's one pace is its fences' (``CEFResizeFences/pace``), handed to each page's hosting with them.
@MainActor
final class CEFFencePace {
    /// `CMUX_NEXT_CEF_FENCE_PACE=adaptive` turns it on (a `CMUX_NEXT_` knob: the launch strip keeps it).
    nonisolated static let isOn = ProcessInfo.processInfo.environment["CMUX_NEXT_CEF_FENCE_PACE"] == "adaptive"

    /// Outcomes judged (one per page per fence).
    static let window = 8
    /// Misses in the last ``window`` that mean the pages fell behind.
    static let behindMisses = 3
    /// How long a window that fell behind waits for no page before probing.
    static let behindSeconds: TimeInterval = 0.12

    struct History: Equatable {
        var outcomes: [Bool] = []
        var behindUntil: TimeInterval = 0
    }

    private(set) var histories: [ObjectIdentifier: History] = [:]
    private let now: () -> TimeInterval

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    /// The wait for a page resize in `window` whose fixed wait is `base` ms; nil holds nothing.
    func wait(window: ObjectIdentifier, base: Int32, refreshMs: Double, windowResized: Bool) -> Int32? {
        let history = histories[window] ?? History()
        let t = now()
        if t < history.behindUntil { return nil }
        let recent = history.outcomes.suffix(Self.window)
        if recent.count >= Self.window, recent.allSatisfy({ $0 }) {
            return Self.longMs(base: base, refreshMs: refreshMs, windowResized: windowResized)
        }
        return base
    }

    /// One page's fence came back: presented (its frame joined the pane's commit) or not.
    func record(window: ObjectIdentifier, presented: Bool) {
        var history = histories[window] ?? History()
        history.outcomes.append(presented)
        if history.outcomes.count > Self.window { history.outcomes.removeFirst(history.outcomes.count - Self.window) }
        if history.outcomes.filter({ !$0 }).count >= Self.behindMisses {
            history.behindUntil = now() + Self.behindSeconds
            // The probe after the pause judges afresh.
            history.outcomes.removeAll()
        }
        if histories[window] == nil, histories.count >= 32 { histories.removeAll() }
        histories[window] = history
    }

    /// The longer wait of a window whose pages keep up: a full display frame inside the window (twice the half frame),
    /// a frame and a half for a resize of the window itself; never shorter than `base`.
    nonisolated static func longMs(base: Int32, refreshMs: Double, windowResized: Bool) -> Int32 {
        let long = Int32((refreshMs * (windowResized ? 1.5 : 1.0)).rounded(.down))
        return max(base, long)
    }
}
