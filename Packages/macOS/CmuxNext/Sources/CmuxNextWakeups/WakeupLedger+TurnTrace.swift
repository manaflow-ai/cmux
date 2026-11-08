import CmuxNextCompat
import Darwin
import Foundation

/// DIAG ONLY (RESIZE P0 17, a -nomerge branch, never lands): what each main run-loop turn did, for `debug.frames`'
/// per-turn record (``MainTurnLog``). Named work on the main thread marks itself (``turnMark(_:)``) or times itself
/// (``turnAdd(_:nanos:)``, ``turnSpan(_:_:)``); the probe takes the turn's tags when the run loop goes to sleep. Off the
/// main thread, or while `debug.frames` does not record, nothing is kept.
public struct TurnTag: Sendable {
    public var count = 0
    public var nanos: UInt64 = 0
}

extension WakeupLedger {
    public static func turnNow() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    /// Starts or stops keeping tags; either way the tags so far go.
    public func setTurnTracing(_ on: Bool) {
        turnTracing.store(on, ordering: .relaxed)
        turnTags.withLock { $0.removeAll(keepingCapacity: true) }
    }

    /// One `name` in this main turn.
    public func turnMark(_ name: @autoclosure () -> String) {
        guard turnTracing.load(ordering: .relaxed), Thread.isMainThread else { return }
        let key = name()
        turnTags.withLock { $0[key, default: TurnTag()].count += 1 }
    }

    /// One `name` in this main turn that took `nanos`.
    public func turnAdd(_ name: @autoclosure () -> String, nanos: UInt64) {
        guard turnTracing.load(ordering: .relaxed), Thread.isMainThread else { return }
        let key = name()
        turnTags.withLock { tags in
            tags[key, default: TurnTag()].count += 1
            tags[key, default: TurnTag()].nanos &+= nanos
        }
    }

    /// Runs `body`, timed under `name` while tags are kept.
    public func turnSpan<T>(_ name: @autoclosure () -> String, _ body: () throws -> T) rethrows -> T {
        guard turnTracing.load(ordering: .relaxed), Thread.isMainThread else { return try body() }
        let start = Self.turnNow()
        defer { turnAdd(name(), nanos: Self.turnNow() &- start) }
        return try body()
    }

    /// This turn's tags as "name count us", longest first; they go.
    public func takeTurnTags() -> String {
        let tags = turnTags.withLock { tags in
            defer { tags.removeAll(keepingCapacity: true) }
            return tags
        }
        return tags.sorted { ($0.value.nanos, $0.value.count) > ($1.value.nanos, $1.value.count) }
            .map { "\($0.key) \($0.value.count) \($0.value.nanos / 1_000)" }
            .joined(separator: ";")
    }
}
