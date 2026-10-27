import CmuxNextCompat
import Foundation
import CmuxNextWakeups

#if DEBUG
/// A slow local daemon for the restore journey (cx-wwtam), debug builds
/// only. `CMUX_NEXT_DEBUG_SLOW_ATTACH=<fails>:<delay ms>` makes every
/// terminal attach wait `delay ms` first, and the first `fails` attaches of
/// each surface then fail, as an attach to a daemon that has not answered
/// yet does. Unset (the default) does nothing.
public nonisolated final class DebugSlowAttach: Sendable {
    public static let shared = DebugSlowAttach(ProcessInfo.processInfo.environment["CMUX_NEXT_DEBUG_SLOW_ATTACH"])

    nonisolated struct Injected: Error, CustomStringConvertible {
        var description: String { "debug slow attach: this attach fails (CMUX_NEXT_DEBUG_SLOW_ATTACH)" }
    }

    private let fails: Int
    private let delay: Duration
    private let failed = Mutex<[String: Int]>([:])

    init(_ spec: String?) {
        let parts = (spec ?? "").split(separator: ":").compactMap { Int($0) }
        fails = parts.first.map { max(0, $0) } ?? 0
        delay = .milliseconds(parts.count > 1 ? max(0, parts[1]) : 0)
    }

    public var isActive: Bool { fails > 0 || delay > .zero }

    /// Runs before each attach of `surface`.
    public func beforeAttach(surface: String) async throws {
        guard isActive else { return }
        // wakeup-allow: debug seam (CMUX_NEXT_DEBUG_SLOW_ATTACH), one wait per attach of a slow-daemon run
        // timer-class-allow: a DEBUG-only fault injection (unset by default): the attach itself waits, no deadline work is scheduled
        try await Task.sleep(for: delay, tolerance: WakeLeeway.window(delay: delay).tolerance)
        let fail = failed.withLock { counts -> Bool in
            let count = counts[surface, default: 0]
            guard count < fails else { return false }
            counts[surface] = count + 1
            return true
        }
        if fail { throw Injected() }
    }
}
#endif
